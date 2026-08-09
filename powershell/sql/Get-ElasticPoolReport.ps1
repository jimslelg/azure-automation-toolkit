#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Sql

<#
.SYNOPSIS
    Reports every Azure SQL elastic pool with its SKU, capacity, storage, and database count.
.DESCRIPTION
    Enumerates the elastic pools of every SQL server in scope (or one resource group with
    -ResourceGroupName) and emits one object per pool with edition, SKU, capacity (DTU or
    vCores), storage, the number of databases in the pool, zone redundancy, and state.
    Read-only; results can be exported with -ExportPath.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ResourceGroupName
    Optional resource group to limit the scan; the whole subscription otherwise.
.PARAMETER ExportPath
    Optional directory to export results to (created if missing; timestamped filename).
.PARAMETER ExportFormat
    Export format when -ExportPath is supplied. Csv (default) or Json.
.EXAMPLE
    ./Get-ElasticPoolReport.ps1

    Reports every elastic pool in the current subscription.
.EXAMPLE
    ./Get-ElasticPoolReport.ps1 -ResourceGroupName rg-data-prod -ExportPath ./output -ExportFormat Json

    Reports the pools of one resource group and exports the results as JSON.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Reader on the target scope.
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure
                (some servers or pools could not be read), 4 invalid parameters/configuration.
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
    Write-ToolkitLog -Message "Reporting elastic pools across $($servers.Count) SQL server(s)"

    $failures = 0
    $itemCount = 0
    $report = foreach ($server in $servers) {
        try {
            $pools = @(Invoke-WithRetry -OperationName "List elastic pools on $($server.ServerName)" -ScriptBlock {
                    Get-AzSqlElasticPool -ServerName $server.ServerName -ResourceGroupName $server.ResourceGroupName
                })
            Write-ToolkitLog -Message 'Server scanned' -Data @{
                server    = $server.ServerName
                poolCount = $pools.Count
            }
        }
        catch {
            $failures++
            $itemCount++
            Write-ToolkitLog -Level Error -Message "Failed to list pools on '$($server.ServerName)'" -ErrorRecord $_
            continue
        }

        foreach ($pool in $pools) {
            $itemCount++
            try {
                $poolDatabases = @(Invoke-WithRetry -OperationName "List databases in pool $($pool.ElasticPoolName)" -ScriptBlock {
                        Get-AzSqlElasticPoolDatabase -ElasticPoolName $pool.ElasticPoolName `
                            -ServerName $server.ServerName -ResourceGroupName $server.ResourceGroupName
                    })

                $capacity = if ($pool.Capacity) { $pool.Capacity } else { $pool.Dtu }
                [pscustomobject]@{
                    ServerName        = $server.ServerName
                    ResourceGroupName = $server.ResourceGroupName
                    PoolName          = $pool.ElasticPoolName
                    Edition           = $pool.Edition
                    SkuName           = $pool.SkuName
                    Capacity          = $capacity
                    StorageMb         = $pool.StorageMB
                    DatabaseCount     = $poolDatabases.Count
                    ZoneRedundant     = $pool.ZoneRedundant
                    State             = $pool.State
                }
            }
            catch {
                $failures++
                Write-ToolkitLog -Level Error -Message "Failed to report pool '$($pool.ElasticPoolName)' on '$($server.ServerName)'" -ErrorRecord $_
            }
        }
    }

    $report = @($report)
    if ($failures -gt 0 -and $failures -lt $itemCount) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $itemCount -gt 0) { throw "Elastic pool report failed for all $failures item(s)." }

    Write-ToolkitLog -Message "$($report.Count) elastic pool(s) reported"
    $report

    if ($ExportPath -and $report.Count -gt 0) {
        $exportParams = @{ InputObject = $report; Name = 'elastic-pool-report'; OutputDirectory = $ExportPath }
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
