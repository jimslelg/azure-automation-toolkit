#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Compute

<#
.SYNOPSIS
    Starts one or more Azure VMs by name or by tag.
.DESCRIPTION
    Starts virtual machines selected either explicitly (-ResourceGroupName + -Name) or
    by tag (-TagName / -TagValue), with per-VM error isolation so one failure does not
    abort the fleet. Supports -WhatIf. Emits a result object per VM to the pipeline.
    Commonly paired with Stop-AzureVm.ps1 on a schedule for business-hours operation.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ResourceGroupName
    Resource group containing the VMs (ByName selection).
.PARAMETER Name
    One or more VM names to start (ByName selection).
.PARAMETER TagName
    Tag key to select VMs by (ByTag selection), e.g. AutoSchedule.
.PARAMETER TagValue
    Optional tag value that must match; any value counts when omitted.
.PARAMETER NoWait
    Issues the start operations without waiting for completion.
.EXAMPLE
    ./Start-AzureVm.ps1 -ResourceGroupName rg-app-prod -Name web-01, web-02

    Starts two VMs and waits for both operations to finish.
.EXAMPLE
    ./Start-AzureVm.ps1 -TagName AutoSchedule -TagValue business-hours -WhatIf

    Previews which tagged VMs would be started.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Virtual Machine Contributor on the target scope.
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure,
                4 invalid parameters/configuration.
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'ByName')]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [ValidateNotNullOrEmpty()]
    [string[]]$Name,

    [Parameter(Mandatory, ParameterSetName = 'ByTag')]
    [ValidateNotNullOrEmpty()]
    [string]$TagName,

    [Parameter(ParameterSetName = 'ByTag')]
    [string]$TagValue,

    [Parameter()]
    [switch]$NoWait
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'AzToolkit.Common.psd1') -Force

$exitCode = 0
try {
    $null = Initialize-ToolkitLog -ScriptName $MyInvocation.MyCommand.Name
    $null = Connect-ToolkitAzure -SubscriptionId $SubscriptionId

    if ($PSCmdlet.ParameterSetName -eq 'ByName') {
        $targetVms = foreach ($vmName in $Name) {
            Invoke-WithRetry -OperationName "Get VM $vmName" -ScriptBlock {
                Get-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName
            }
        }
    }
    else {
        Write-ToolkitLog -Message "Selecting VMs by tag '$TagName'" -Data @{ tagValue = $TagValue }
        $targetVms = Invoke-WithRetry -OperationName 'List VMs' -ScriptBlock { Get-AzVM } |
            Where-Object {
                $_.Tags.ContainsKey($TagName) -and (-not $TagValue -or $_.Tags[$TagName] -eq $TagValue)
            }
    }

    $targetVms = @($targetVms)
    if ($targetVms.Count -eq 0) {
        Write-ToolkitLog -Level Warning -Message 'No VMs matched the selection criteria'
    }

    $failures = 0
    $results = foreach ($vm in $targetVms) {
        if (-not $PSCmdlet.ShouldProcess($vm.Name, 'Start VM')) {
            continue
        }
        try {
            Write-ToolkitLog -Message 'Starting VM' -Data @{ vm = $vm.Name; resourceGroup = $vm.ResourceGroupName }
            $operation = Invoke-WithRetry -OperationName "Start $($vm.Name)" -ScriptBlock {
                Start-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -NoWait:$NoWait
            }
            [pscustomobject]@{
                Name              = $vm.Name
                ResourceGroupName = $vm.ResourceGroupName
                Location          = $vm.Location
                Status            = if ($NoWait) { 'StartRequested' } else { $operation.Status }
            }
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Failed to start '$($vm.Name)'" -ErrorRecord $_
            [pscustomobject]@{
                Name              = $vm.Name
                ResourceGroupName = $vm.ResourceGroupName
                Location          = $vm.Location
                Status            = 'Failed'
            }
        }
    }

    if ($failures -gt 0 -and $failures -lt $targetVms.Count) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $targetVms.Count -gt 0) { throw "All $failures VM start operation(s) failed." }

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
