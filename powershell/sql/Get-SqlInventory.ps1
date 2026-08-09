#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Sql

<#
.SYNOPSIS
    Inventories every Azure SQL database across the SQL servers in scope.
.DESCRIPTION
    Lists all Azure SQL servers in the subscription (or one resource group with
    -ResourceGroupName) and emits one object per user database with edition, SKU,
    size, elastic pool membership, zone redundancy, status, and creation date. The
    master database is skipped. Read-only; results can be exported with -ExportPath.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ResourceGroupName
    Optional resource group to limit the scan; the whole subscription otherwise.
.PARAMETER ExportPath
    Optional directory to export results to (created if missing; timestamped filename).
.PARAMETER ExportFormat
    Export format when -ExportPath is supplied. Csv (default) or Json.
.EXAMPLE
    ./Get-SqlInventory.ps1

    Inventories every SQL database in the current subscription.
.EXAMPLE
    ./Get-SqlInventory.ps1 -ResourceGroupName rg-data-prod -ExportPath ./output -ExportFormat Json

    Inventories one resource group and exports the report as JSON.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Reader on the target scope.
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure
                (some servers could not be enumerated), 4 invalid parameters/configuration.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$ResourceGroupName,

    [Parameter()]
    [string]$ExportPath,

    [Parameter()]
    [ValidateSet('Csv', 'Json')]
    [string]$ExportFormat = 'Csv'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'AzToolkit.Common.psd1') -Force

$exitCode = 0
try {
    $null = Initialize-ToolkitLog -ScriptName $MyInvocation.MyCommand.Name
    $null = Connect-ToolkitAzure -SubscriptionId $SubscriptionId

    $getServerParams = @{}
    if ($ResourceGroupName) {
        $getServerParams.ResourceGroupName = $ResourceGroupName
    }
    $servers = @(Invoke-WithRetry -OperationName 'List SQL servers' -ScriptBlock { Get-AzSqlServer @getServerParams })

    if ($servers.Count -eq 0) {
        Write-ToolkitLog -Level Warning -Message 'No SQL servers matched the selection criteria'
    }
    Write-ToolkitLog -Message "Inventorying $($servers.Count) SQL server(s)"

    $failures = 0
    $inventory = foreach ($server in $servers) {
        try {
            $databases = @(Invoke-WithRetry -OperationName "List databases on $($server.ServerName)" -ScriptBlock {
                    Get-AzSqlDatabase -ServerName $server.ServerName -ResourceGroupName $server.ResourceGroupName
                } | Where-Object DatabaseName -NE 'master')

            Write-ToolkitLog -Message 'Server inventoried' -Data @{
                server        = $server.ServerName
                databaseCount = $databases.Count
            }

            foreach ($database in $databases) {
                [pscustomobject]@{
                    ServerName        = $server.ServerName
                    ResourceGroupName = $server.ResourceGroupName
                    DatabaseName      = $database.DatabaseName
                    Edition           = $database.Edition
                    SkuName           = $database.SkuName
                    CurrentSku        = $database.CurrentServiceObjectiveName
                    MaxSizeGb         = [Math]::Round($database.MaxSizeBytes / 1GB, 2)
                    ElasticPoolName   = $database.ElasticPoolName
                    ZoneRedundant     = $database.ZoneRedundant
                    Status            = $database.Status
                    CreationDate      = $database.CreationDate
                }
            }
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Failed to inventory server '$($server.ServerName)'" -ErrorRecord $_
        }
    }

    $inventory = @($inventory)
    if ($failures -gt 0 -and $failures -lt $servers.Count) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $servers.Count -gt 0) { throw "Inventory failed for all $failures server(s)." }

    Write-ToolkitLog -Message "$($inventory.Count) database(s) inventoried"
    $inventory

    if ($ExportPath -and $inventory.Count -gt 0) {
        $exportParams = @{ InputObject = $inventory; Name = 'sql-inventory'; OutputDirectory = $ExportPath }
        $null = if ($ExportFormat -eq 'Csv') { Export-ToolkitCsv @exportParams } else { Export-ToolkitJson @exportParams }
    }
}
catch {
    $exitCode = switch -Wildcard ($_.FullyQualifiedErrorId) {
        'AzToolkit.AuthenticationFailed*' { 2 }
        'AzToolkit.ConfigurationInvalid*' { 4 }
        default { 1 }
    }
    Write-ToolkitLog -Level Error -Message "Unhandled failure: $($_.Exception.Message)" -ErrorRecord $_
    Write-Error -ErrorRecord $_ -ErrorAction Continue
}
finally {
    Write-ToolkitLog -Message "Completed with exit code $exitCode"
}
exit $exitCode
