#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Compute

<#
.SYNOPSIS
    Deletes managed disk snapshots older than a minimum age.
.DESCRIPTION
    Scans the subscription (or one resource group) for snapshots older than
    -MinimumAgeDays (measured from TimeCreated) and deletes them. Snapshots carrying
    the -ExcludeTagName tag are skipped. Every deletion is gated by ShouldProcess, so
    -WhatIf previews safely. Each result object reports whether the snapshot's source
    disk still exists (informational - old snapshots of deleted disks may be the last
    copy of that data). Emits one result object per candidate (Deleted/Skipped/Failed).
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ResourceGroupName
    Optional resource group to limit the scan; the whole subscription otherwise.
.PARAMETER MinimumAgeDays
    Minimum snapshot age in days (from TimeCreated) before it qualifies for deletion (default 90).
.PARAMETER ExcludeTagName
    Snapshots carrying a tag with this name are never deleted (default 'DoNotDelete').
.EXAMPLE
    ./Remove-UnusedSnapshots.ps1 -MinimumAgeDays 90 -WhatIf

    Previews which snapshots older than 90 days would be deleted.
.EXAMPLE
    ./Remove-UnusedSnapshots.ps1 -ResourceGroupName rg-backups -Confirm:$false

    Deletes qualifying snapshots in one resource group without prompting.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Contributor (or Disk Snapshot Contributor) on the target scope.
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure,
                4 invalid parameters/configuration.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$ResourceGroupName,

    [Parameter()]
    [ValidateRange(0, 3650)]
    [int]$MinimumAgeDays = 90,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$ExcludeTagName = 'DoNotDelete'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'AzToolkit.Common.psd1') -Force

$exitCode = 0
try {
    $null = Initialize-ToolkitLog -ScriptName $MyInvocation.MyCommand.Name
    $null = Connect-ToolkitAzure -SubscriptionId $SubscriptionId

    $getSnapshotParams = @{}
    if ($ResourceGroupName) {
        $getSnapshotParams.ResourceGroupName = $ResourceGroupName
    }
    $snapshots = @(Invoke-WithRetry -OperationName 'List snapshots' -ScriptBlock { Get-AzSnapshot @getSnapshotParams })

    $cutoffUtc = [datetime]::UtcNow.AddDays(-$MinimumAgeDays)
    $candidates = @($snapshots | Where-Object { $_.TimeCreated.ToUniversalTime() -lt $cutoffUtc })

    Write-ToolkitLog -Message "$($candidates.Count) snapshot(s) older than $MinimumAgeDays day(s) found" -Data @{
        totalSnapshots = $snapshots.Count
        candidates     = $candidates.Count
    }
    if ($candidates.Count -eq 0) {
        Write-ToolkitLog -Level Warning -Message 'No snapshots matched the age criteria'
    }

    $failures = 0
    $results = foreach ($snapshot in $candidates) {
        $ageDays = [int][Math]::Floor(([datetime]::UtcNow - $snapshot.TimeCreated.ToUniversalTime()).TotalDays)
        $status = $null
        $reason = $null

        # Informational: does the source disk this snapshot was taken from still exist?
        $sourceDiskExists = $null
        $sourceResourceId = $snapshot.CreationData.SourceResourceId
        if ($sourceResourceId -and $sourceResourceId -match '/resourceGroups/(?<rg>[^/]+)/providers/Microsoft\.Compute/disks/(?<disk>[^/]+)$') {
            $sourceRg = $Matches.rg
            $sourceDiskName = $Matches.disk
            $sourceDiskExists = [bool](Invoke-WithRetry -OperationName "Check source disk of $($snapshot.Name)" -ScriptBlock {
                    Get-AzDisk -ResourceGroupName $sourceRg -DiskName $sourceDiskName -ErrorAction SilentlyContinue
                })
        }

        if ($snapshot.Tags -and $snapshot.Tags.ContainsKey($ExcludeTagName)) {
            Write-ToolkitLog -Message "Skipping '$($snapshot.Name)' - carries exclude tag" -Data @{ tag = $ExcludeTagName }
            $status = 'Skipped'
            $reason = "Tag '$ExcludeTagName' present"
        }
        elseif (-not $PSCmdlet.ShouldProcess($snapshot.Name, "Remove snapshot ($($snapshot.DiskSizeGB) GB, $ageDays day(s) old)")) {
            $status = 'Skipped'
            $reason = 'Confirmation declined or -WhatIf'
        }
        else {
            try {
                Write-ToolkitLog -Message 'Deleting snapshot' -Data @{
                    snapshot         = $snapshot.Name
                    resourceGroup    = $snapshot.ResourceGroupName
                    ageDays          = $ageDays
                    sourceDiskExists = $sourceDiskExists
                }
                $null = Invoke-WithRetry -OperationName "Remove snapshot $($snapshot.Name)" -ScriptBlock {
                    Remove-AzSnapshot -ResourceGroupName $snapshot.ResourceGroupName -SnapshotName $snapshot.Name -Force
                }
                $status = 'Deleted'
            }
            catch {
                $failures++
                Write-ToolkitLog -Level Error -Message "Failed to delete snapshot '$($snapshot.Name)'" -ErrorRecord $_
                $status = 'Failed'
                $reason = $_.Exception.Message
            }
        }

        [pscustomobject]@{
            Name              = $snapshot.Name
            ResourceGroupName = $snapshot.ResourceGroupName
            SizeGb            = $snapshot.DiskSizeGB
            AgeDays           = $ageDays
            SourceDiskExists  = $sourceDiskExists
            Status            = $status
            Reason            = $reason
        }
    }

    if ($failures -gt 0 -and $failures -lt $candidates.Count) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $candidates.Count -gt 0) { throw "All $failures snapshot deletion(s) failed." }

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
