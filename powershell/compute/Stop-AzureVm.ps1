#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Compute

<#
.SYNOPSIS
    Stops (deallocates) one or more Azure VMs by name or by tag.
.DESCRIPTION
    Stops virtual machines selected either explicitly (-ResourceGroupName + -Name) or
    by tag (-TagName / -TagValue). VMs are deallocated by default so compute charges
    stop; use -StayProvisioned to keep the allocation (still billed). Per-VM error
    isolation, -WhatIf support, and one result object per VM on the pipeline.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ResourceGroupName
    Resource group containing the VMs (ByName selection).
.PARAMETER Name
    One or more VM names to stop (ByName selection).
.PARAMETER TagName
    Tag key to select VMs by (ByTag selection), e.g. AutoSchedule.
.PARAMETER TagValue
    Optional tag value that must match; any value counts when omitted.
.PARAMETER StayProvisioned
    Powers the OS off but keeps the VM allocated (compute billing continues).
.PARAMETER NoWait
    Issues the stop operations without waiting for completion.
.EXAMPLE
    ./Stop-AzureVm.ps1 -ResourceGroupName rg-app-dev -Name web-01 -WhatIf

    Shows what would be deallocated without doing it.
.EXAMPLE
    ./Stop-AzureVm.ps1 -TagName AutoSchedule -TagValue business-hours

    Evening scale-down of every VM carrying the AutoSchedule=business-hours tag.
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
    [switch]$StayProvisioned,

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

    $action = if ($StayProvisioned) { 'Stop VM (stay provisioned)' } else { 'Deallocate VM' }
    $failures = 0
    $results = foreach ($vm in $targetVms) {
        if (-not $PSCmdlet.ShouldProcess($vm.Name, $action)) {
            continue
        }
        try {
            Write-ToolkitLog -Message 'Stopping VM' -Data @{
                vm              = $vm.Name
                resourceGroup   = $vm.ResourceGroupName
                stayProvisioned = [bool]$StayProvisioned
            }
            $operation = Invoke-WithRetry -OperationName "Stop $($vm.Name)" -ScriptBlock {
                Stop-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name `
                    -StayProvisioned:$StayProvisioned -NoWait:$NoWait -Force
            }
            [pscustomobject]@{
                Name              = $vm.Name
                ResourceGroupName = $vm.ResourceGroupName
                Location          = $vm.Location
                Deallocated       = -not $StayProvisioned
                Status            = if ($NoWait) { 'StopRequested' } else { $operation.Status }
            }
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Failed to stop '$($vm.Name)'" -ErrorRecord $_
            [pscustomobject]@{
                Name              = $vm.Name
                ResourceGroupName = $vm.ResourceGroupName
                Location          = $vm.Location
                Deallocated       = $false
                Status            = 'Failed'
            }
        }
    }

    if ($failures -gt 0 -and $failures -lt $targetVms.Count) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $targetVms.Count -gt 0) { throw "All $failures VM stop operation(s) failed." }

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
