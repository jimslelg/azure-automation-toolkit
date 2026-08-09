#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Network

<#
.SYNOPSIS
    Reports every public IP address with its SKU, allocation, association, and DDoS state.
.DESCRIPTION
    Lists all public IP addresses in scope and flattens the operationally useful
    properties: assigned IP, SKU, allocation method, the resource the IP configuration
    belongs to (or 'Unassociated' when it hangs loose), and the DDoS protection mode.
    Read-only: the output feeds cost cleanups (unassociated standard SKU IPs still
    bill) and exposure reviews. Emits one object per public IP and can export the
    report with -ExportPath.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ResourceGroupName
    Optional resource group to limit the scan; the whole subscription otherwise.
.PARAMETER ExportPath
    Optional directory to export results to (created if missing; timestamped filename).
.PARAMETER ExportFormat
    Export format when -ExportPath is supplied. Csv (default) or Json.
.EXAMPLE
    ./Get-PublicIpAddresses.ps1

    Reports every public IP in the subscription.
.EXAMPLE
    ./Get-PublicIpAddresses.ps1 -ResourceGroupName rg-network -ExportPath ./output -ExportFormat Json

    Scans one resource group and exports the report as JSON.
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

    $pipParams = @{}
    if ($ResourceGroupName) {
        $pipParams.ResourceGroupName = $ResourceGroupName
    }
    $publicIps = @(Invoke-WithRetry -OperationName 'List public IP addresses' -ScriptBlock {
            Get-AzPublicIpAddress @pipParams
        })
    Write-ToolkitLog -Message "Reporting $($publicIps.Count) public IP address(es)"

    $failures = 0
    $report = foreach ($pip in $publicIps) {
        try {
            $associatedName = 'Unassociated'
            $associatedType = 'Unassociated'
            if ($pip.IpConfiguration -and $pip.IpConfiguration.Id) {
                $segments = $pip.IpConfiguration.Id -split '/'
                if ($segments.Count -ge 9) {
                    $associatedType = $segments[7]
                    $associatedName = $segments[8]
                }
            }

            [pscustomobject]@{
                Name                   = $pip.Name
                ResourceGroupName      = $pip.ResourceGroupName
                Location               = $pip.Location
                IpAddress              = $pip.IpAddress
                SkuName                = $pip.Sku.Name
                AllocationMethod       = $pip.PublicIpAllocationMethod
                AssociatedResource     = $associatedName
                AssociatedResourceType = $associatedType
                DdosProtection         = if ($pip.DdosSettings -and $pip.DdosSettings.ProtectionMode) { $pip.DdosSettings.ProtectionMode } else { 'Disabled' }
            }
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Failed processing public IP '$($pip.Name)'" -ErrorRecord $_
        }
    }

    $report = @($report)
    if ($failures -gt 0 -and $failures -lt $publicIps.Count) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $publicIps.Count -gt 0) { throw "All $failures public IP(s) failed processing." }

    $unassociated = @($report | Where-Object AssociatedResource -EQ 'Unassociated').Count
    Write-ToolkitLog -Message "$unassociated of $($report.Count) public IP(s) are unassociated"
    $report

    if ($ExportPath -and $report.Count -gt 0) {
        $exportParams = @{ InputObject = $report; Name = 'public-ip-addresses'; OutputDirectory = $ExportPath }
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
