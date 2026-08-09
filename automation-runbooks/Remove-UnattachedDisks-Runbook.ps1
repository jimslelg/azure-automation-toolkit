<#
.SYNOPSIS
    Azure Automation runbook: weekly cleanup of unattached managed disks.
.DESCRIPTION
    Runs on a schedule with the Automation Account's system-assigned managed identity
    and deletes managed disks that have been unattached for at least -MinimumAgeDays.
    Defaults to ReportOnly=$true: the job output lists what WOULD be deleted, and an
    operator flips ReportOnly to $false on the schedule once the report has been
    reviewed. Disks tagged with the exclusion tag (default DoNotDelete) are always
    skipped. Self-contained by design: no custom module dependencies.
.PARAMETER MinimumAgeDays
    Minimum age (from TimeCreated) before an unattached disk qualifies. Default: 30.
.PARAMETER ExcludeTagName
    Disks carrying this tag key are never deleted. Default: DoNotDelete.
.PARAMETER SubscriptionId
    Subscription to operate on. Defaults to the managed identity's default subscription.
.PARAMETER ReportOnly
    When $true (default), reports candidates without deleting anything.
.EXAMPLE
    Start-AzAutomationRunbook -AutomationAccountName aa-ops -ResourceGroupName rg-ops `
        -Name 'Remove-UnattachedDisks-Runbook' -Parameters @{ ReportOnly = $false }

    Executes the cleanup for real after the report has been reviewed.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Automation Account managed identity with Contributor (or Disk-scoped
              custom role) on the subscription.
    Failure  : throws, marking the Automation job as Failed.
#>
param(
    [Parameter()]
    [int]$MinimumAgeDays = 30,

    [Parameter()]
    [string]$ExcludeTagName = 'DoNotDelete',

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [bool]$ReportOnly = $true
)

$ErrorActionPreference = 'Stop'

# Authenticate as the Automation Account's system-assigned managed identity.
$null = Disable-AzContextAutosave -Scope Process
$null = Connect-AzAccount -Identity
if ($SubscriptionId) {
    $null = Set-AzContext -SubscriptionId $SubscriptionId
}

$cutoff = (Get-Date).AddDays(-$MinimumAgeDays)
$candidates = @(Get-AzDisk | Where-Object {
        $_.DiskState -eq 'Unattached' -and
        -not $_.ManagedBy -and
        $_.TimeCreated -lt $cutoff -and
        -not ($_.Tags -and $_.Tags.ContainsKey($ExcludeTagName))
    })

$totalGb = ($candidates | Measure-Object -Property DiskSizeGB -Sum).Sum
Write-Output "Found $($candidates.Count) unattached disk(s) older than $MinimumAgeDays day(s), $totalGb GB total"

$failed = 0
foreach ($disk in $candidates) {
    $ageDays = [int]((Get-Date) - $disk.TimeCreated).TotalDays
    if ($ReportOnly) {
        Write-Output "[ReportOnly] Would delete: $($disk.ResourceGroupName)/$($disk.Name) ($($disk.DiskSizeGB) GB, $ageDays days old, sku $($disk.Sku.Name))"
        continue
    }
    try {
        Write-Verbose "Deleting $($disk.Name)"
        $null = Remove-AzDisk -ResourceGroupName $disk.ResourceGroupName -DiskName $disk.Name -Force
        Write-Output "Deleted: $($disk.ResourceGroupName)/$($disk.Name) ($($disk.DiskSizeGB) GB)"
    }
    catch {
        $failed++
        Write-Warning "Failed to delete $($disk.Name): $($_.Exception.Message)"
    }
}

if ($failed -gt 0) {
    throw "$failed of $($candidates.Count) disk deletion(s) failed."
}
Write-Output 'Completed successfully'
