#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.ResourceGraph

<#
.SYNOPSIS
    Finds orphaned ("zombie") resources that cost money or clutter the subscription.
.DESCRIPTION
    Runs one Azure Resource Graph query per zombie class and collects the findings:
    unattached managed disks, unassociated public IPs, NICs bound to no VM or private
    endpoint, empty availability sets, load balancers without backend pools, App
    Service plans with zero sites, and snapshots older than 180 days. Read-only.
    Each finding carries a category, name, resource group, location, a detail column,
    and an estimated monthly waste note where one is cheap to infer (otherwise null).
    Resource Graph paging is handled via -First 1000 plus SkipToken loops.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ExportPath
    Optional directory to export results to (created if missing; timestamped filename).
.PARAMETER ExportFormat
    Export format when -ExportPath is supplied. Csv (default) or Json.
.EXAMPLE
    ./Get-ZombieResources.ps1

    Reports all zombie resources in the current subscription to the pipeline.
.EXAMPLE
    ./Get-ZombieResources.ps1 -ExportPath ./output -ExportFormat Json

    Reports zombie resources and exports the findings as JSON.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Reader on the target scope.
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure
                (some queries failed), 4 invalid parameters/configuration.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$ExportPath,

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

    # Approximate monthly storage cost per GB (USD) for waste estimates.
    $diskRates = @{
        Standard_LRS    = 0.05
        StandardSSD_LRS = 0.075
        Premium_LRS     = 0.135
    }

    $zombieQueries = @(
        @{
            Category = 'UnattachedDisk'
            Query    = @'
resources
| where type =~ 'microsoft.compute/disks'
| where tostring(properties.diskState) =~ 'Unattached' and isempty(managedBy)
| project name, resourceGroup, location, sizeGb = toint(properties.diskSizeGB), skuName = tostring(sku.name),
    detail = strcat('sku=', tostring(sku.name), '; sizeGb=', tostring(properties.diskSizeGB))
'@
        }
        @{
            Category = 'UnassociatedPublicIp'
            Query    = @'
resources
| where type =~ 'microsoft.network/publicipaddresses'
| where isempty(properties.ipConfiguration) and isempty(properties.natGateway)
| project name, resourceGroup, location, skuName = tostring(sku.name),
    detail = strcat('sku=', tostring(sku.name), '; allocation=', tostring(properties.publicIPAllocationMethod))
'@
        }
        @{
            Category = 'OrphanedNic'
            Query    = @'
resources
| where type =~ 'microsoft.network/networkinterfaces'
| where isempty(properties.virtualMachine) and isempty(properties.privateEndpoint)
| project name, resourceGroup, location,
    detail = strcat('ipConfigurations=', tostring(array_length(properties.ipConfigurations)))
'@
        }
        @{
            Category = 'EmptyAvailabilitySet'
            Query    = @'
resources
| where type =~ 'microsoft.compute/availabilitysets'
| where array_length(properties.virtualMachines) == 0
| project name, resourceGroup, location, detail = 'no virtual machines'
'@
        }
        @{
            Category = 'LoadBalancerNoBackend'
            Query    = @'
resources
| where type =~ 'microsoft.network/loadbalancers'
| where array_length(properties.backendAddressPools) == 0
| project name, resourceGroup, location, skuName = tostring(sku.name),
    detail = strcat('sku=', tostring(sku.name), '; no backend pools')
'@
        }
        @{
            Category = 'EmptyAppServicePlan'
            Query    = @'
resources
| where type =~ 'microsoft.web/serverfarms'
| where toint(properties.numberOfSites) == 0
| project name, resourceGroup, location, skuName = tostring(sku.name),
    detail = strcat('sku=', tostring(sku.name), '; sites=0')
'@
        }
        @{
            Category = 'OldSnapshot'
            Query    = @'
resources
| where type =~ 'microsoft.compute/snapshots'
| where todatetime(properties.timeCreated) < ago(180d)
| project name, resourceGroup, location, sizeGb = toint(properties.diskSizeGB),
    detail = strcat('created=', tostring(properties.timeCreated))
'@
        }
    )

    $findings = [System.Collections.Generic.List[pscustomobject]]::new()
    $failures = 0

    foreach ($definition in $zombieQueries) {
        try {
            $rows = Get-GraphQueryResult -Query $definition.Query -OperationName "Query $($definition.Category)"
            Write-ToolkitLog -Message "$($rows.Count) finding(s)" -Data @{ category = $definition.Category }

            foreach ($row in $rows) {
                $wasteNote = switch ($definition.Category) {
                    'UnattachedDisk' {
                        $rate = $diskRates[[string]$row.skuName]
                        if ($rate -and $row.sizeGb) { '~${0}/mo ({1} approx)' -f [Math]::Round($rate * [int]$row.sizeGb, 2), $row.skuName } else { $null }
                    }
                    'UnassociatedPublicIp' { '~$3.65/mo (idle public IP)' }
                    'LoadBalancerNoBackend' { if ([string]$row.skuName -eq 'Standard') { '~$18.25/mo (Standard LB base)' } else { $null } }
                    'OldSnapshot' { if ($row.sizeGb) { '~${0}/mo (snapshot storage approx)' -f [Math]::Round(0.05 * [int]$row.sizeGb, 2) } else { $null } }
                    default { $null }
                }

                $findings.Add([pscustomobject]@{
                        Category              = $definition.Category
                        Name                  = $row.name
                        ResourceGroupName     = $row.resourceGroup
                        Location              = $row.location
                        Detail                = $row.detail
                        EstimatedMonthlyWaste = $wasteNote
                    })
            }
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Query failed for category '$($definition.Category)'" -ErrorRecord $_
        }
    }

    if ($failures -gt 0 -and $failures -lt $zombieQueries.Count) { $exitCode = 3 }
    elseif ($failures -gt 0) { throw "All $failures zombie queries failed." }

    Write-ToolkitLog -Message "$($findings.Count) zombie resource(s) found across $($zombieQueries.Count) categories"
    $findings

    if ($ExportPath -and $findings.Count -gt 0) {
        $exportParams = @{ InputObject = $findings; Name = 'zombie-resources'; OutputDirectory = $ExportPath }
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
