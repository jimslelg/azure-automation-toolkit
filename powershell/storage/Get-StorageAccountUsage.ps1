#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Storage, Az.Monitor

<#
.SYNOPSIS
    Reports capacity usage and key configuration for every storage account in scope.
.DESCRIPTION
    For each storage account, reads the latest 'UsedCapacity' metric (Average
    aggregation) from Azure Monitor and combines it with the account's SKU, kind,
    access tier, minimum TLS version, and public network access setting. Read-only:
    the output feeds capacity and security posture reviews. Emits one object per
    account and can export the report with -ExportPath.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ResourceGroupName
    Optional resource group to limit the scan; the whole subscription otherwise.
.PARAMETER ExportPath
    Optional directory to export results to (created if missing; timestamped filename).
.PARAMETER ExportFormat
    Export format when -ExportPath is supplied. Csv (default) or Json.
.EXAMPLE
    ./Get-StorageAccountUsage.ps1

    Reports usage and configuration for every storage account in the subscription.
.EXAMPLE
    ./Get-StorageAccountUsage.ps1 -ResourceGroupName rg-data -ExportPath ./output

    Scans one resource group and exports the report as CSV.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Reader + Monitoring Reader on the target scope.
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure
                (some accounts' metrics unavailable), 4 invalid parameters/configuration.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$ResourceGroupName,

    [Parameter()]
    [string]$ExportPath,

    [Parameter()]
    [ValidateSet('Csv', 'Json')]
    [string]$ExportFormat = 'Csv'
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
    }
    $accounts = @(Invoke-WithRetry -OperationName 'List storage accounts' -ScriptBlock {
            Get-AzStorageAccount @accountParams
        })
    Write-ToolkitLog -Message "Collecting usage for $($accounts.Count) storage account(s)"

    $endTime = Get-Date
    $startTime = $endTime.AddDays(-1)
    $failures = 0

    $usage = foreach ($account in $accounts) {
        try {
            $metrics = Invoke-WithRetry -OperationName "UsedCapacity metric for $($account.StorageAccountName)" -ScriptBlock {
                Get-AzMetric -ResourceId $account.Id -MetricName 'UsedCapacity' `
                    -StartTime $startTime -EndTime $endTime `
                    -TimeGrain ([timespan]::FromHours(1)) -AggregationType Average `
                    -WarningAction SilentlyContinue
            }
            $latestSample = @($metrics.Data |
                    Where-Object { $null -ne $_.Average } |
                    Sort-Object TimeStamp |
                    Select-Object -Last 1)
            $usedBytes = if ($latestSample.Count -gt 0) { [long]$latestSample[0].Average } else { $null }

            [pscustomobject]@{
                StorageAccountName  = $account.StorageAccountName
                ResourceGroupName   = $account.ResourceGroupName
                Location            = $account.Location
                SkuName             = $account.Sku.Name
                Kind                = $account.Kind
                AccessTier          = $account.AccessTier
                MinimumTlsVersion   = $account.MinimumTlsVersion
                PublicNetworkAccess = if ($account.PublicNetworkAccess) { $account.PublicNetworkAccess } else { 'Unknown' }
                UsedCapacityBytes   = $usedBytes
                UsedCapacityGb      = if ($null -ne $usedBytes) { [Math]::Round($usedBytes / 1GB, 2) } else { $null }
            }
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Failed to collect usage for '$($account.StorageAccountName)'" -ErrorRecord $_
        }
    }

    $usage = @($usage)
    if ($failures -gt 0 -and $failures -lt $accounts.Count) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $accounts.Count -gt 0) { throw "Usage collection failed for all $failures account(s)." }

    Write-ToolkitLog -Message "Collected usage for $($usage.Count) storage account(s)"
    $usage

    if ($ExportPath -and $usage.Count -gt 0) {
        $exportParams = @{ InputObject = $usage; Name = 'storage-account-usage'; OutputDirectory = $ExportPath }
        $null = if ($ExportFormat -eq 'Csv') { Export-ToolkitCsv @exportParams } else { Export-ToolkitJson @exportParams }
    }
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
