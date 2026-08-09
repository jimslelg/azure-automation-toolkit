#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Storage, Az.Monitor

<#
.SYNOPSIS
    Finds storage accounts with zero transactions over a lookback window - deletion candidates.
.DESCRIPTION
    Queries the Azure Monitor 'Transactions' metric (Total aggregation) for every storage
    account in scope and reports accounts that recorded zero transactions over the
    lookback window. Read-only: the output feeds decommissioning reviews. Emits one
    object per orphaned account including its age, SKU, and access tier, and can export
    the report with -ExportPath.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ResourceGroupName
    Optional resource group to limit the scan; the whole subscription otherwise.
.PARAMETER LookbackDays
    Days of metric history to evaluate (default 30).
.PARAMETER ExportPath
    Optional directory to export results to (created if missing; timestamped filename).
.PARAMETER ExportFormat
    Export format when -ExportPath is supplied. Csv (default) or Json.
.EXAMPLE
    ./Get-OrphanedStorageAccounts.ps1 -LookbackDays 30

    Reports subscription-wide storage accounts with no transactions in the last month.
.EXAMPLE
    ./Get-OrphanedStorageAccounts.ps1 -ResourceGroupName rg-data -ExportPath ./output -ExportFormat Json

    Scans one resource group and exports the findings as JSON.
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
    [ValidateRange(1, 90)]
    [int]$LookbackDays = 30,

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
    Write-ToolkitLog -Message "Evaluating $($accounts.Count) storage account(s) over the last $LookbackDays day(s)"

    $endTime = Get-Date
    $startTime = $endTime.AddDays(-$LookbackDays)
    $failures = 0

    $orphaned = foreach ($account in $accounts) {
        try {
            $metrics = Invoke-WithRetry -OperationName "Transactions metric for $($account.StorageAccountName)" -ScriptBlock {
                Get-AzMetric -ResourceId $account.Id -MetricName 'Transactions' `
                    -StartTime $startTime -EndTime $endTime `
                    -TimeGrain ([timespan]::FromDays(1)) -AggregationType Total `
                    -WarningAction SilentlyContinue
            }
            $samples = @($metrics.Data | Where-Object { $null -ne $_.Total })
            $totalTransactions = ($samples.Total | Measure-Object -Sum).Sum
            if ($null -eq $totalTransactions) { $totalTransactions = 0 }

            if ($totalTransactions -eq 0) {
                Write-ToolkitLog -Message 'Orphaned storage account found' -Data @{
                    account       = $account.StorageAccountName
                    resourceGroup = $account.ResourceGroupName
                }
                [pscustomobject]@{
                    StorageAccountName = $account.StorageAccountName
                    ResourceGroupName  = $account.ResourceGroupName
                    Location           = $account.Location
                    SkuName            = $account.Sku.Name
                    Kind               = $account.Kind
                    AccessTier         = $account.AccessTier
                    CreationTime       = $account.CreationTime
                    AgeDays            = [int]((Get-Date) - $account.CreationTime).TotalDays
                    TotalTransactions  = [long]$totalTransactions
                    LookbackDays       = $LookbackDays
                }
            }
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Failed to evaluate '$($account.StorageAccountName)'" -ErrorRecord $_
        }
    }

    $orphaned = @($orphaned)
    if ($failures -gt 0 -and $failures -lt $accounts.Count) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $accounts.Count -gt 0) { throw "Metric evaluation failed for all $failures account(s)." }

    Write-ToolkitLog -Message "$($orphaned.Count) storage account(s) had zero transactions in the last $LookbackDays day(s)"
    $orphaned

    if ($ExportPath -and $orphaned.Count -gt 0) {
        $exportParams = @{ InputObject = $orphaned; Name = 'orphaned-storage-accounts'; OutputDirectory = $ExportPath }
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
