#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Storage

<#
.SYNOPSIS
    Deletes blobs in a container that have not been modified for a minimum number of days.
.DESCRIPTION
    Lists blobs in the given container (optionally narrowed with -Prefix), selects those
    whose LastModified timestamp is older than -MinimumAgeDays, and deletes them oldest
    first up to the -MaxBlobs safety cap. Every deletion is gated through ShouldProcess,
    so -WhatIf previews the cleanup. Emits one result object per targeted blob with the
    outcome, size, and last-modified timestamp.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ResourceGroupName
    Resource group containing the storage account.
.PARAMETER StorageAccountName
    Storage account containing the container to clean.
.PARAMETER ContainerName
    Blob container to clean.
.PARAMETER Prefix
    Optional blob name prefix to narrow the scan.
.PARAMETER MinimumAgeDays
    Blobs must be at least this many days old to be deleted (default 180).
.PARAMETER MaxBlobs
    Safety cap on how many blobs a single run may delete (default 5000).
.EXAMPLE
    ./Remove-UnusedBlobs.ps1 -ResourceGroupName rg-data -StorageAccountName stdata01 -ContainerName archive -WhatIf

    Previews which blobs older than 180 days would be deleted from the archive container.
.EXAMPLE
    ./Remove-UnusedBlobs.ps1 -ResourceGroupName rg-data -StorageAccountName stdata01 -ContainerName logs -Prefix 'app1/' -MinimumAgeDays 365 -MaxBlobs 1000

    Deletes up to 1000 blobs under app1/ that have not been modified in a year.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Storage Blob Data Contributor (or account key access) on the target account.
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
    [string]$StorageAccountName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ContainerName,

    [Parameter()]
    [string]$Prefix,

    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$MinimumAgeDays = 180,

    [Parameter()]
    [ValidateRange(1, 1000000)]
    [int]$MaxBlobs = 5000
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'AzToolkit.Common.psd1') -Force

$exitCode = 0
try {
    $null = Initialize-ToolkitLog -ScriptName $MyInvocation.MyCommand.Name
    $null = Connect-ToolkitAzure -SubscriptionId $SubscriptionId

    $account = Invoke-WithRetry -OperationName "Get storage account $StorageAccountName" -ScriptBlock {
        Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
    }

    $blobParams = @{ Container = $ContainerName; Context = $account.Context }
    if ($Prefix) {
        $blobParams.Prefix = $Prefix
    }
    $blobs = @(Invoke-WithRetry -OperationName "List blobs in $ContainerName" -ScriptBlock {
            Get-AzStorageBlob @blobParams
        })

    $cutoffUtc = (Get-Date).ToUniversalTime().AddDays(-$MinimumAgeDays)
    $staleBlobs = @($blobs |
            Where-Object { $_.LastModified.UtcDateTime -lt $cutoffUtc } |
            Sort-Object { $_.LastModified })
    if ($staleBlobs.Count -gt $MaxBlobs) {
        Write-ToolkitLog -Level Warning -Message "$($staleBlobs.Count) stale blob(s) found; capping this run at -MaxBlobs $MaxBlobs"
        $staleBlobs = @($staleBlobs | Select-Object -First $MaxBlobs)
    }

    Write-ToolkitLog -Message 'Stale blob selection complete' -Data @{
        account        = $StorageAccountName
        container      = $ContainerName
        prefix         = $Prefix
        minimumAgeDays = $MinimumAgeDays
        targeted       = $staleBlobs.Count
    }

    $failures = 0
    $results = foreach ($blob in $staleBlobs) {
        if (-not $PSCmdlet.ShouldProcess("$StorageAccountName/$ContainerName/$($blob.Name)", "Delete blob not modified in $MinimumAgeDays day(s)")) {
            continue
        }
        try {
            Invoke-WithRetry -OperationName "Delete blob $($blob.Name)" -ScriptBlock {
                Remove-AzStorageBlob -Blob $blob.Name -Container $ContainerName -Context $account.Context -Force
            }
            [pscustomobject]@{
                StorageAccountName = $StorageAccountName
                Container          = $ContainerName
                BlobName           = $blob.Name
                LastModified       = $blob.LastModified.UtcDateTime
                SizeBytes          = [long]$blob.Length
                Status             = 'Deleted'
            }
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Failed to delete blob '$($blob.Name)'" -ErrorRecord $_
            [pscustomobject]@{
                StorageAccountName = $StorageAccountName
                Container          = $ContainerName
                BlobName           = $blob.Name
                LastModified       = $blob.LastModified.UtcDateTime
                SizeBytes          = [long]$blob.Length
                Status             = 'Failed'
            }
        }
    }

    $results = @($results)
    if ($failures -gt 0 -and $failures -lt $staleBlobs.Count) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $staleBlobs.Count -gt 0) { throw "All $failures blob deletion(s) failed." }

    $deletedCount = @($results | Where-Object Status -EQ 'Deleted').Count
    $bytesFreed = (@($results | Where-Object Status -EQ 'Deleted').SizeBytes | Measure-Object -Sum).Sum
    Write-ToolkitLog -Message "Deleted $deletedCount blob(s), freed $([long]($bytesFreed ?? 0)) byte(s), $failures failure(s)"

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
