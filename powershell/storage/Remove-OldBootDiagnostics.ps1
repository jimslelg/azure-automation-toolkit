#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Storage

<#
.SYNOPSIS
    Deletes stale boot diagnostics blobs from 'bootdiagnostics-*' storage containers.
.DESCRIPTION
    Scans storage accounts in scope for containers whose name matches 'bootdiagnostics-*'
    (the containers Azure creates for VM boot diagnostics) and deletes blobs whose
    LastModified timestamp is older than -MinimumAgeDays. Deletion is gated per container
    through ShouldProcess, so -WhatIf previews the cleanup. Emits one summary object per
    container with the blob count and bytes freed.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ResourceGroupName
    Optional resource group to limit the scan; the whole subscription otherwise.
.PARAMETER StorageAccountName
    Optional storage account name to limit the scan to a single account.
.PARAMETER MinimumAgeDays
    Blobs must be at least this many days old to be deleted (default 90).
.EXAMPLE
    ./Remove-OldBootDiagnostics.ps1 -WhatIf

    Previews which boot diagnostics blobs would be deleted subscription-wide.
.EXAMPLE
    ./Remove-OldBootDiagnostics.ps1 -ResourceGroupName rg-app-dev -MinimumAgeDays 30

    Deletes boot diagnostics blobs older than 30 days in one resource group.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Storage Blob Data Contributor (or account key access) on the target scope.
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
    [string]$StorageAccountName,

    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$MinimumAgeDays = 90
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'AzToolkit.Common.psd1') -Force

$exitCode = 0
try {
    $null = Initialize-ToolkitLog -ScriptName $MyInvocation.MyCommand.Name
    $null = Connect-ToolkitAzure -SubscriptionId $SubscriptionId

    $accountParams = @{}
    if ($ResourceGroupName) {
        $accountParams.ResourceGroupName = $ResourceGroupName
        if ($StorageAccountName) {
            $accountParams.Name = $StorageAccountName
        }
    }
    $accounts = @(Invoke-WithRetry -OperationName 'List storage accounts' -ScriptBlock {
            Get-AzStorageAccount @accountParams
        })
    if ($StorageAccountName -and -not $ResourceGroupName) {
        $accounts = @($accounts | Where-Object StorageAccountName -EQ $StorageAccountName)
    }

    $cutoffUtc = (Get-Date).ToUniversalTime().AddDays(-$MinimumAgeDays)
    Write-ToolkitLog -Message "Scanning $($accounts.Count) storage account(s) for boot diagnostics blobs older than $MinimumAgeDays day(s)"

    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    $failures = 0
    $succeeded = 0

    foreach ($account in $accounts) {
        try {
            $containers = @(Invoke-WithRetry -OperationName "List containers in $($account.StorageAccountName)" -ScriptBlock {
                    Get-AzStorageContainer -Context $account.Context
                } | Where-Object Name -Like 'bootdiagnostics-*')
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Failed to list containers in '$($account.StorageAccountName)'" -ErrorRecord $_
            continue
        }

        foreach ($container in $containers) {
            try {
                $staleBlobs = @(Invoke-WithRetry -OperationName "List blobs in $($container.Name)" -ScriptBlock {
                        Get-AzStorageBlob -Container $container.Name -Context $account.Context
                    } | Where-Object { $_.LastModified.UtcDateTime -lt $cutoffUtc })

                if ($staleBlobs.Count -eq 0) {
                    $succeeded++
                    continue
                }

                $target = "$($account.StorageAccountName)/$($container.Name)"
                $action = "Delete $($staleBlobs.Count) boot diagnostics blob(s) older than $MinimumAgeDays day(s)"
                if (-not $PSCmdlet.ShouldProcess($target, $action)) {
                    $succeeded++
                    continue
                }

                $deleted = 0
                $bytesFreed = [long]0
                $blobFailures = 0
                foreach ($blob in $staleBlobs) {
                    try {
                        Invoke-WithRetry -OperationName "Delete blob $($blob.Name)" -ScriptBlock {
                            Remove-AzStorageBlob -Blob $blob.Name -Container $container.Name -Context $account.Context -Force
                        }
                        $deleted++
                        $bytesFreed += [long]$blob.Length
                    }
                    catch {
                        $blobFailures++
                        Write-ToolkitLog -Level Error -Message "Failed to delete blob '$($blob.Name)' in '$target'" -ErrorRecord $_
                    }
                }

                Write-ToolkitLog -Message 'Boot diagnostics cleanup' -Data @{
                    account      = $account.StorageAccountName
                    container    = $container.Name
                    blobsDeleted = $deleted
                    bytesFreed   = $bytesFreed
                }
                $results.Add([pscustomobject]@{
                        StorageAccountName = $account.StorageAccountName
                        ResourceGroupName  = $account.ResourceGroupName
                        Container          = $container.Name
                        BlobsDeleted       = $deleted
                        BytesFreed         = $bytesFreed
                        BlobFailures       = $blobFailures
                    })

                if ($blobFailures -gt 0) { $failures++ } else { $succeeded++ }
            }
            catch {
                $failures++
                Write-ToolkitLog -Level Error -Message "Failed processing container '$($container.Name)' in '$($account.StorageAccountName)'" -ErrorRecord $_
            }
        }
    }

    if ($failures -gt 0 -and $succeeded -gt 0) { $exitCode = 3 }
    elseif ($failures -gt 0) { throw "All $failures work item(s) failed processing." }

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
