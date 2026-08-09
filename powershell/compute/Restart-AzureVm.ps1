#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Compute

<#
.SYNOPSIS
    Restarts one or more Azure VMs with per-VM error isolation.
.DESCRIPTION
    Restarts the named virtual machines one at a time, optionally pausing between
    restarts (-DelaySeconds) so a fleet of stateful nodes is never bounced all at
    once. Supports -WhatIf and emits a result object per VM.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ResourceGroupName
    Resource group containing the VMs.
.PARAMETER Name
    One or more VM names to restart.
.PARAMETER DelaySeconds
    Seconds to wait between consecutive restarts (default 0 = no delay).
.EXAMPLE
    ./Restart-AzureVm.ps1 -ResourceGroupName rg-app-prod -Name web-01

    Restarts a single VM and waits for the operation to complete.
.EXAMPLE
    ./Restart-AzureVm.ps1 -ResourceGroupName rg-app-prod -Name web-01, web-02, web-03 -DelaySeconds 120

    Rolling restart with a two-minute gap between nodes.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Virtual Machine Contributor on the target scope.
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure,
                4 invalid parameters/configuration.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$Name,

    [Parameter()]
    [ValidateRange(0, 3600)]
    [int]$DelaySeconds = 0
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'AzToolkit.Common.psd1') -Force

$exitCode = 0
try {
    $null = Initialize-ToolkitLog -ScriptName $MyInvocation.MyCommand.Name
    $null = Connect-ToolkitAzure -SubscriptionId $SubscriptionId

    $failures = 0
    $processed = 0
    $results = foreach ($vmName in $Name) {
        if (-not $PSCmdlet.ShouldProcess($vmName, 'Restart VM')) {
            continue
        }
        if ($processed -gt 0 -and $DelaySeconds -gt 0) {
            Write-ToolkitLog -Message "Waiting $DelaySeconds seconds before the next restart"
            Start-Sleep -Seconds $DelaySeconds
        }
        $processed++
        try {
            Write-ToolkitLog -Message 'Restarting VM' -Data @{ vm = $vmName; resourceGroup = $ResourceGroupName }
            $operation = Invoke-WithRetry -OperationName "Restart $vmName" -ScriptBlock {
                Restart-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName
            }
            [pscustomobject]@{
                Name              = $vmName
                ResourceGroupName = $ResourceGroupName
                Status            = $operation.Status
            }
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Failed to restart '$vmName'" -ErrorRecord $_
            [pscustomobject]@{
                Name              = $vmName
                ResourceGroupName = $ResourceGroupName
                Status            = 'Failed'
            }
        }
    }

    if ($failures -gt 0 -and $failures -lt $Name.Count) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $processed -gt 0) { throw "All $failures VM restart operation(s) failed." }

    $results
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
