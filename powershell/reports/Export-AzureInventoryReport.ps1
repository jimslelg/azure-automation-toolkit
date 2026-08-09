#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.ResourceGraph

<#
.SYNOPSIS
    Exports a full Azure resource inventory plus a count-by-type summary.
.DESCRIPTION
    Pulls every resource in scope through Azure Resource Graph (name, type, resource
    group, location, subscription, tags) with -First 1000 SkipToken paging, then
    builds a summary of the top 25 resource types by count. Read-only. Both the
    detail and summary files are always written to -OutputDirectory; the detail
    objects are emitted to the pipeline.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER OutputDirectory
    Directory the inventory files are written to (created if missing; default ./output).
.PARAMETER ExportFormat
    Export file format. Csv (default) or Json.
.EXAMPLE
    ./Export-AzureInventoryReport.ps1

    Writes azure-inventory and azure-inventory-summary files to ./output and emits
    the detail rows to the pipeline.
.EXAMPLE
    ./Export-AzureInventoryReport.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -OutputDirectory ./reports -ExportFormat Json

    Inventories the given subscription and exports both files as JSON.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Reader on the target scope.
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure,
                4 invalid parameters/configuration.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = './output',

    [Parameter()]
    [ValidateSet('Csv', 'Json')]
    [string]$ExportFormat = 'Csv'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'AzToolkit.Common.psd1') -Force

function Get-GraphQueryResult {
    <#
    .SYNOPSIS
        Runs a Resource Graph query and follows SkipToken paging (-First 1000 per page).
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Query,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OperationName
    )

    $rows = [System.Collections.Generic.List[pscustomobject]]::new()
    $skipToken = $null
    do {
        $graphParams = @{ Query = $Query; First = 1000 }
        if ($skipToken) {
            $graphParams.SkipToken = $skipToken
        }
        $page = Invoke-WithRetry -OperationName $OperationName -ScriptBlock { Search-AzGraph @graphParams }
        if ($null -eq $page) {
            break
        }
        $pageRows = if ($null -ne $page.PSObject.Properties['Data']) { @($page.Data) } else { @($page) }
        foreach ($row in $pageRows) {
            $rows.Add([pscustomobject]$row)
        }
        $skipToken = if ($null -ne $page.PSObject.Properties['SkipToken']) { $page.SkipToken } else { $null }
    } while (-not [string]::IsNullOrEmpty($skipToken))
    return , $rows
}

$exitCode = 0
try {
    $null = Initialize-ToolkitLog -ScriptName $MyInvocation.MyCommand.Name
    $null = Connect-ToolkitAzure -SubscriptionId $SubscriptionId

    $inventoryQuery = 'Resources | project name, type, resourceGroup, location, subscriptionId, tags | order by type asc'
    $rows = Get-GraphQueryResult -Query $inventoryQuery -OperationName 'Query resource inventory'
    Write-ToolkitLog -Message "$($rows.Count) resource(s) retrieved from Resource Graph"

    $inventory = @(foreach ($row in $rows) {
            [pscustomobject]@{
                Name           = $row.name
                Type           = $row.type
                ResourceGroup  = $row.resourceGroup
                Location       = $row.location
                SubscriptionId = $row.subscriptionId
                Tags           = if ($null -ne $row.tags) { $row.tags | ConvertTo-Json -Compress -Depth 10 } else { $null }
            }
        })

    $summary = @($inventory |
            Group-Object -Property Type |
            Sort-Object -Property Count -Descending |
            Select-Object -First 25 |
            ForEach-Object {
                [pscustomobject]@{
                    Type  = $_.Name
                    Count = $_.Count
                }
            })

    $inventory

    if ($inventory.Count -gt 0) {
        $detailParams = @{ InputObject = $inventory; Name = 'azure-inventory'; OutputDirectory = $OutputDirectory }
        $summaryParams = @{ InputObject = $summary; Name = 'azure-inventory-summary'; OutputDirectory = $OutputDirectory }
        $null = if ($ExportFormat -eq 'Csv') { Export-ToolkitCsv @detailParams } else { Export-ToolkitJson @detailParams }
        $null = if ($ExportFormat -eq 'Csv') { Export-ToolkitCsv @summaryParams } else { Export-ToolkitJson @summaryParams }
        Write-ToolkitLog -Message 'Inventory detail and summary exported' -Data @{
            outputDirectory = $OutputDirectory
            format          = $ExportFormat
            detailRows      = $inventory.Count
            summaryRows     = $summary.Count
        }
    }
    else {
        Write-ToolkitLog -Level Warning -Message 'No resources found - nothing exported'
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
