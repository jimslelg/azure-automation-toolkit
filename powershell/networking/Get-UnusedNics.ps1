#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Network

<#
.SYNOPSIS
    Finds network interfaces attached to neither a VM nor a private endpoint - cleanup candidates.
.DESCRIPTION
    Lists every network interface in scope and reports those whose VirtualMachine and
    PrivateEndpoint references are both null, meaning nothing consumes the NIC. When
    the NIC carries a creation-hint tag (CreatedOn, CreatedDate, CreationDate) it is
    surfaced to help judge how long the NIC has been idle. Read-only: the output feeds
    orphaned-resource cleanups. Emits one object per unused NIC and can export the
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
    ./Get-UnusedNics.ps1

    Reports every unused NIC in the subscription.
.EXAMPLE
    ./Get-UnusedNics.ps1 -ResourceGroupName rg-app-dev -ExportPath ./output

    Scans one resource group and exports the findings as CSV.
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

    $nicParams = @{}
    if ($ResourceGroupName) {
        $nicParams.ResourceGroupName = $ResourceGroupName
    }
    $nics = @(Invoke-WithRetry -OperationName 'List network interfaces' -ScriptBlock {
            Get-AzNetworkInterface @nicParams
        })
    $unusedNics = @($nics | Where-Object { $null -eq $_.VirtualMachine -and $null -eq $_.PrivateEndpoint })
    Write-ToolkitLog -Message "$($unusedNics.Count) of $($nics.Count) NIC(s) are attached to neither a VM nor a private endpoint"

    $creationTagKeys = @('CreatedOn', 'CreatedDate', 'CreationDate', 'created-on', 'created')
    $failures = 0
    $report = foreach ($nic in $unusedNics) {
        try {
            $createdHint = $null
            if ($nic.Tag) {
                foreach ($key in $creationTagKeys) {
                    if ($nic.Tag.ContainsKey($key)) {
                        $createdHint = "$key=$($nic.Tag[$key])"
                        break
                    }
                }
            }

            [pscustomobject]@{
                Name              = $nic.Name
                ResourceGroupName = $nic.ResourceGroupName
                Location          = $nic.Location
                PrivateIpAddress  = (@($nic.IpConfigurations.PrivateIpAddress) -join ';')
                SubnetId          = (@($nic.IpConfigurations.Subnet.Id) -join ';')
                CreatedHint       = $createdHint
                Tags              = if ($nic.Tag) { ($nic.Tag.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';' } else { '' }
            }
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Failed processing NIC '$($nic.Name)'" -ErrorRecord $_
        }
    }

    $report = @($report)
    if ($failures -gt 0 -and $failures -lt $unusedNics.Count) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $unusedNics.Count -gt 0) { throw "All $failures NIC(s) failed processing." }

    $report

    if ($ExportPath -and $report.Count -gt 0) {
        $exportParams = @{ InputObject = $report; Name = 'unused-nics'; OutputDirectory = $ExportPath }
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
