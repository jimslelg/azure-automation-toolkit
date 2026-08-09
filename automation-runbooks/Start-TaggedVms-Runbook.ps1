<#
.SYNOPSIS
    Azure Automation runbook: starts every VM carrying the scheduling tag.
.DESCRIPTION
    Designed to run on a morning schedule in an Azure Automation Account using the
    account's system-assigned managed identity. Starts all VMs in the subscription
    whose tag (default AutoSchedule=business-hours) matches and that are not already
    running. Pair with Stop-TaggedVms-Runbook.ps1 on an evening schedule.
    Self-contained by design: no custom module or file-system dependencies.
.PARAMETER TagName
    Tag key that opts a VM into scheduling. Default: AutoSchedule.
.PARAMETER TagValue
    Tag value that must match. Default: business-hours.
.PARAMETER SubscriptionId
    Subscription to operate on. Defaults to the managed identity's default subscription.
.PARAMETER ReportOnly
    When $true, only reports the VMs that would be started. Default: $false
    (scheduled runs are expected to act).
.EXAMPLE
    Start-AzAutomationRunbook -AutomationAccountName aa-ops -ResourceGroupName rg-ops `
        -Name 'Start-TaggedVms-Runbook' -Parameters @{ TagValue = 'business-hours' }

    Triggers the runbook on demand from PowerShell.
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
        $_.Tags -and $_.Tags[$TagName] -eq $TagValue -and $_.PowerState -ne 'VM running'
    })
Write-Output "Found $($vms.Count) stopped VM(s) tagged $TagName=$TagValue"

$failed = 0
foreach ($vm in $vms) {
    if ($ReportOnly) {
        Write-Output "[ReportOnly] Would start: $($vm.ResourceGroupName)/$($vm.Name)"
        continue
    }
    try {
        Write-Verbose "Starting $($vm.Name)"
        $null = Start-AzVM -ResourceGroupName $vm.ResourceGroupName -Name $vm.Name -NoWait
        Write-Output "Start requested: $($vm.ResourceGroupName)/$($vm.Name)"
    }
    catch {
        $failed++
        Write-Warning "Failed to start $($vm.Name): $($_.Exception.Message)"
    }
}

if ($failed -gt 0) {
    throw "$failed of $($vms.Count) VM start operation(s) failed."
}
Write-Output 'Completed successfully'
