#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Compute

<#
.SYNOPSIS
    Deletes managed disks that are unattached and older than a minimum age.
.DESCRIPTION
    Scans the subscription (or one resource group) for managed disks whose DiskState is
    'Unattached' and whose ManagedBy reference is empty, then deletes those older than
    -MinimumAgeDays (measured from TimeCreated). Disks carrying the -ExcludeTagName tag
    are skipped. Every deletion is gated by ShouldProcess, so -WhatIf previews safely.
    Emits one result object per candidate disk (Deleted/Skipped/Failed).
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ResourceGroupName
    Optional resource group to limit the scan; the whole subscription otherwise.
.PARAMETER MinimumAgeDays
    Minimum disk age in days (from TimeCreated) before it qualifies for deletion (default 30).
.PARAMETER ExcludeTagName
    Disks carrying a tag with this name are never deleted (default 'DoNotDelete').
.EXAMPLE
    ./Remove-UnattachedDisks.ps1 -MinimumAgeDays 30 -WhatIf

    Previews which unattached disks older than 30 days would be deleted.
.EXAMPLE
    ./Remove-UnattachedDisks.ps1 -ResourceGroupName rg-app-dev -Confirm:$false

    Deletes qualifying unattached disks in one resource group without prompting.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Contributor (or Disk Contributor) on the target scope.
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
    [int]$MinimumAgeDays = 30,

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

    $getDiskParams = @{}
    if ($ResourceGroupName) {
        $getDiskParams.ResourceGroupName = $ResourceGroupName
    }
    $disks = @(Invoke-WithRetry -OperationName 'List managed disks' -ScriptBlock { Get-AzDisk @getDiskParams })

    $cutoffUtc = [datetime]::UtcNow.AddDays(-$MinimumAgeDays)
    $candidates = @($disks | Where-Object {
            $_.DiskState -eq 'Unattached' -and
            [string]::IsNullOrEmpty($_.ManagedBy) -and
            $_.TimeCreated.ToUniversalTime() -lt $cutoffUtc
        })

    Write-ToolkitLog -Message "$($candidates.Count) unattached disk(s) older than $MinimumAgeDays day(s) found" -Data @{
        totalDisks = $disks.Count
        candidates = $candidates.Count
    }
    if ($candidates.Count -eq 0) {
        Write-ToolkitLog -Level Warning -Message 'No unattached disks matched the age criteria'
    }

    $failures = 0
    $results = foreach ($disk in $candidates) {
        $ageDays = [int][Math]::Floor(([datetime]::UtcNow - $disk.TimeCreated.ToUniversalTime()).TotalDays)
        $status = $null
        $reason = $null

        if ($disk.Tags -and $disk.Tags.ContainsKey($ExcludeTagName)) {
            Write-ToolkitLog -Message "Skipping '$($disk.Name)' - carries exclude tag" -Data @{ tag = $ExcludeTagName }
            $status = 'Skipped'
            $reason = "Tag '$ExcludeTagName' present"
        }
        elseif (-not $PSCmdlet.ShouldProcess($disk.Name, "Remove unattached managed disk ($($disk.DiskSizeGB) GB, $ageDays day(s) old)")) {
            $status = 'Skipped'
            $reason = 'Confirmation declined or -WhatIf'
        }
        else {
            try {
                Write-ToolkitLog -Message 'Deleting unattached disk' -Data @{
                    disk          = $disk.Name
                    resourceGroup = $disk.ResourceGroupName
                    sizeGb        = $disk.DiskSizeGB
                    ageDays       = $ageDays
                }
                $null = Invoke-WithRetry -OperationName "Remove disk $($disk.Name)" -ScriptBlock {
                    Remove-AzDisk -ResourceGroupName $disk.ResourceGroupName -DiskName $disk.Name -Force
                }
                $status = 'Deleted'
            }
            catch {
                $failures++
                Write-ToolkitLog -Level Error -Message "Failed to delete disk '$($disk.Name)'" -ErrorRecord $_
                $status = 'Failed'
                $reason = $_.Exception.Message
            }
        }

        [pscustomobject]@{
            Name              = $disk.Name
            ResourceGroupName = $disk.ResourceGroupName
            SizeGb            = $disk.DiskSizeGB
            Sku               = $disk.Sku.Name
            AgeDays           = $ageDays
            Status            = $status
            Reason            = $reason
        }
    }

    if ($failures -gt 0 -and $failures -lt $candidates.Count) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $candidates.Count -gt 0) { throw "All $failures disk deletion(s) failed." }

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
