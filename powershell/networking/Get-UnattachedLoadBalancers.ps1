#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Network

<#
.SYNOPSIS
    Finds load balancers whose backend pools are all empty - decommissioning candidates.
.DESCRIPTION
    Lists every load balancer in scope and reports those where every backend address
    pool is empty (no backend IP configurations and no load balancer backend
    addresses), including load balancers with no backend pools at all. Read-only:
    the output feeds cost cleanups since standard SKU load balancers bill while
    serving nothing. Emits one object per unattached load balancer with SKU,
    frontend, rule, and pool counts, and can export the report with -ExportPath.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ResourceGroupName
    Optional resource group to limit the scan; the whole subscription otherwise.
.PARAMETER ExportPath
    Optional directory to export results to (created if missing; timestamped filename).
.PARAMETER ExportFormat
    Export format when -ExportPath is supplied. Csv (default) or Json.
.EXAMPLE
    ./Get-UnattachedLoadBalancers.ps1

    Reports every load balancer with no backends in the subscription.
.EXAMPLE
    ./Get-UnattachedLoadBalancers.ps1 -ResourceGroupName rg-network -ExportPath ./output -ExportFormat Json

    Scans one resource group and exports the findings as JSON.
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

    $lbParams = @{}
    if ($ResourceGroupName) {
        $lbParams.ResourceGroupName = $ResourceGroupName
    }
    $loadBalancers = @(Invoke-WithRetry -OperationName 'List load balancers' -ScriptBlock {
            Get-AzLoadBalancer @lbParams
        })
    Write-ToolkitLog -Message "Evaluating $($loadBalancers.Count) load balancer(s)"

    $failures = 0
    $unattached = foreach ($lb in $loadBalancers) {
        try {
            $populatedPools = @($lb.BackendAddressPools | Where-Object {
                    @($_.BackendIpConfigurations).Count -gt 0 -or @($_.LoadBalancerBackendAddresses).Count -gt 0
                })
            if ($populatedPools.Count -gt 0) {
                continue
            }

            Write-ToolkitLog -Message 'Unattached load balancer found' -Data @{
                loadBalancer  = $lb.Name
                resourceGroup = $lb.ResourceGroupName
            }
            [pscustomobject]@{
                Name              = $lb.Name
                ResourceGroupName = $lb.ResourceGroupName
                Location          = $lb.Location
                SkuName           = $lb.Sku.Name
                BackendPoolCount  = @($lb.BackendAddressPools).Count
                FrontendCount     = @($lb.FrontendIpConfigurations).Count
                RuleCount         = @($lb.LoadBalancingRules).Count
                InboundNatRules   = @($lb.InboundNatRules).Count
            }
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Failed to evaluate load balancer '$($lb.Name)'" -ErrorRecord $_
        }
    }

    $unattached = @($unattached)
    if ($failures -gt 0 -and $failures -lt $loadBalancers.Count) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $loadBalancers.Count -gt 0) { throw "All $failures load balancer(s) failed evaluation." }

    Write-ToolkitLog -Message "$($unattached.Count) load balancer(s) have no backend targets"
    $unattached

    if ($ExportPath -and $unattached.Count -gt 0) {
        $exportParams = @{ InputObject = $unattached; Name = 'unattached-load-balancers'; OutputDirectory = $ExportPath }
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
