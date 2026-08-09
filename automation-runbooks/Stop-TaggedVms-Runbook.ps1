<#
.SYNOPSIS
    Azure Automation runbook: deallocates every VM carrying the scheduling tag.
.DESCRIPTION
    The evening counterpart to Start-TaggedVms-Runbook.ps1, run on a schedule with the
    Automation Account's system-assigned managed identity. Deallocates all running VMs
    whose tag (default AutoSchedule=business-hours) matches, stopping compute charges
    outside business hours. Self-contained by design: no custom module dependencies.
.PARAMETER TagName
    Tag key that opts a VM into scheduling. Default: AutoSchedule.
.PARAMETER TagValue
    Tag value that must match. Default: business-hours.
.PARAMETER SubscriptionId
    Subscription to operate on. Defaults to the managed identity's default subscription.
.PARAMETER ReportOnly
    When $true, only reports the VMs that would be deallocated. Default: $false
    (scheduled runs are expected to act).
.EXAMPLE
    Start-AzAutomationRunbook -AutomationAccountName aa-ops -ResourceGroupName rg-ops `
        -Name 'Stop-TaggedVms-Runbook' -Parameters @{ ReportOnly = $true }

    Dry run: lists the VMs the evening schedule would deallocate.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Automation Account managed identity with Virtual Machine Contributor.
    Failure  : throws, marking the Automation job as Failed.
#>
param(
    [Parameter()]
    [string]$TagName = 'AutoSchedule',

    [Parameter()]
    [string]$TagValue = 'business-hours',

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [bool]$ReportOnly = $false
)

$ErrorActionPreference = 'Stop'

# Authenticate as the Automation Account's system-assigned managed identity.
$null = Disable-AzContextAutosave -Scope Process
$null = Connect-AzAccount -Identity
if ($SubscriptionId) {
    $null = Set-AzContext -SubscriptionId $SubscriptionId
}

$vms = @(Get-AzVM -Status | Where-Object {
        $_.Tags -and $_.Tags[$TagName] -eq $TagValue -and $_.PowerState -eq 'VM running'
    })
Write-Output "Found $($vms.Count) running VM(s) tagged $TagName=$TagValue"

$failed = 0
foreach ($vm in $vms) {
    if ($ReportOnly) {
        Write-Output "[ReportOnly] Would deallocate: $($vm.ResourceGroupName)/$($vm.Name)"
        continue
    }
    try {
        Write-Verbose "Deallocating $($vm.Name)"
        $null = Stop-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -Force -NoWait
        Write-Output "Deallocation requested: $($vm.ResourceGroupName)/$($vm.Name)"
    }
    catch {
        $failed++
        Write-Warning "Failed to deallocate $($vm.Name): $($_.Exception.Message)"
    }
}

if ($failed -gt 0) {
    throw "$failed of $($vms.Count) VM stop operation(s) failed."
}
Write-Output 'Completed successfully'
