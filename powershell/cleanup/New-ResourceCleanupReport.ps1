#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.ResourceGraph

<#
.SYNOPSIS
    Builds a cleanup summary report of zombie resources grouped by category and resource group.
.DESCRIPTION
    Aggregates the same zombie classes as Get-ZombieResources.ps1 (unattached disks,
    unassociated public IPs, orphaned NICs, empty availability sets, load balancers
    without backend pools, empty App Service plans, snapshots older than 180 days)
    via Azure Resource Graph and emits one summary row per category and resource
    group plus a totals row per category. Queries are read-only; the report file
    write is gated by ShouldProcess and always lands in -OutputDirectory.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER OutputDirectory
    Directory the report file is written to (created if missing; default ./output).
.PARAMETER ExportFormat
    Report file format. Csv (default) or Json.
.EXAMPLE
    ./New-ResourceCleanupReport.ps1

    Writes a CSV cleanup report to ./output and emits the summary rows.
.EXAMPLE
    ./New-ResourceCleanupReport.ps1 -OutputDirectory ./reports -ExportFormat Json -WhatIf

    Shows the summary rows and where the report would be written, without writing it.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Reader on the target scope.
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure
                (some queries failed), 4 invalid parameters/configuration.
#>
[CmdletBinding(SupportsShouldProcess)]
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

    $categoryFilters = @(
        @{
            Category = 'UnattachedDisk'
            Filter   = "resources | where type =~ 'microsoft.compute/disks' | where tostring(properties.diskState) =~ 'Unattached' and isempty(managedBy)"
        }
        @{
            Category = 'UnassociatedPublicIp'
            Filter   = "resources | where type =~ 'microsoft.network/publicipaddresses' | where isempty(properties.ipConfiguration) and isempty(properties.natGateway)"
        }
        @{
            Category = 'OrphanedNic'
            Filter   = "resources | where type =~ 'microsoft.network/networkinterfaces' | where isempty(properties.virtualMachine) and isempty(properties.privateEndpoint)"
        }
        @{
            Category = 'EmptyAvailabilitySet'
            Filter   = "resources | where type =~ 'microsoft.compute/availabilitysets' | where array_length(properties.virtualMachines) == 0"
        }
        @{
            Category = 'LoadBalancerNoBackend'
            Filter   = "resources | where type =~ 'microsoft.network/loadbalancers' | where array_length(properties.backendAddressPools) == 0"
        }
        @{
            Category = 'EmptyAppServicePlan'
            Filter   = "resources | where type =~ 'microsoft.web/serverfarms' | where toint(properties.numberOfSites) == 0"
        }
        @{
            Category = 'OldSnapshot'
            Filter   = "resources | where type =~ 'microsoft.compute/snapshots' | where todatetime(properties.timeCreated) < ago(180d)"
        }
    )

    $summaryRows = [System.Collections.Generic.List[pscustomobject]]::new()
    $failures = 0

    foreach ($definition in $categoryFilters) {
        try {
            $query = $definition.Filter + ' | summarize resourceCount = count() by resourceGroup | order by resourceCount desc'
            $rows = Get-GraphQueryResult -Query $query -OperationName "Summarize $($definition.Category)"

            $categoryTotal = 0
            foreach ($row in $rows) {
                $summaryRows.Add([pscustomobject]@{
                        Category      = $definition.Category
                        ResourceGroup = $row.resourceGroup
                        Count         = [int]$row.resourceCount
                    })
                $categoryTotal += [int]$row.resourceCount
            }

            # Totals row per category (always present, even when the category is clean).
            $summaryRows.Add([pscustomobject]@{
                    Category      = $definition.Category
                    ResourceGroup = '(total)'
                    Count         = $categoryTotal
                })
            Write-ToolkitLog -Message "Category summarized" -Data @{
                category = $definition.Category
                total    = $categoryTotal
            }
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Query failed for category '$($definition.Category)'" -ErrorRecord $_
        }
    }

    if ($failures -gt 0 -and $failures -lt $categoryFilters.Count) { $exitCode = 3 }
    elseif ($failures -gt 0) { throw "All $failures cleanup report queries failed." }

    $summaryRows

    if ($summaryRows.Count -gt 0 -and $PSCmdlet.ShouldProcess($OutputDirectory, "Write resource cleanup report ($ExportFormat)")) {
        $exportParams = @{ InputObject = $summaryRows; Name = 'resource-cleanup-report'; OutputDirectory = $OutputDirectory }
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
