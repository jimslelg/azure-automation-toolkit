#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.CostManagement

<#
.SYNOPSIS
    Exports a monthly Azure cost report grouped by resource group, service, or resource type.
.DESCRIPTION
    Queries Cost Management for month-to-date cost (or a full historical month via
    -BillingMonth 'yyyy-MM') aggregated as Sum(PreTaxCost) with no granularity and
    grouped by the -GroupBy dimension. Read-only. Emits one row per dimension value
    (cost rounded to 2 decimals, sorted descending) and always writes the report to
    -OutputDirectory. Invoke-AzCostManagementQuery returns Row/Column arrays; columns
    are mapped by index from the returned column names.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER BillingMonth
    Historical month to report in 'yyyy-MM' form (e.g. '2026-07'). Defaults to the
    current month-to-date when omitted.
.PARAMETER GroupBy
    Dimension to group cost by: ResourceGroup (default), ServiceName, or ResourceType.
.PARAMETER OutputDirectory
    Directory the report file is written to (created if missing; default ./output).
.PARAMETER ExportFormat
    Report file format. Csv (default) or Json.
.EXAMPLE
    ./Export-MonthlyCostReport.ps1

    Reports current month-to-date cost per resource group and exports a CSV to ./output.
.EXAMPLE
    ./Export-MonthlyCostReport.ps1 -BillingMonth 2026-07 -GroupBy ServiceName -ExportFormat Json

    Reports July 2026 cost per Azure service and exports the report as JSON.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Cost Management Reader on the subscription.
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure,
                4 invalid parameters/configuration.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter()]
    [ValidatePattern('^$|^\d{4}-(0[1-9]|1[0-2])$')]
    [string]$BillingMonth,

    [Parameter()]
    [ValidateSet('ResourceGroup', 'ServiceName', 'ResourceType')]
    [string]$GroupBy = 'ResourceGroup',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = './output',

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

    $targetSubscriptionId = if ($SubscriptionId) { $SubscriptionId } else { (Get-AzContext).Subscription.Id }
    $scope = "/subscriptions/$targetSubscriptionId"

    if ($BillingMonth) {
        $periodFrom = [datetime]::ParseExact($BillingMonth, 'yyyy-MM', [cultureinfo]::InvariantCulture)
        $periodTo = $periodFrom.AddMonths(1).AddSeconds(-1)
    }
    else {
        $now = Get-Date
        $periodFrom = [datetime]::new($now.Year, $now.Month, 1)
        $periodTo = $now
    }

    Write-ToolkitLog -Message 'Querying Cost Management' -Data @{
        scope   = $scope
        from    = $periodFrom.ToString('yyyy-MM-dd')
        to      = $periodTo.ToString('yyyy-MM-dd')
        groupBy = $GroupBy
    }

    $response = Invoke-WithRetry -OperationName 'Query cost data' -ScriptBlock {
        Invoke-AzCostManagementQuery -Scope $scope -Type 'ActualCost' -Timeframe 'Custom' `
            -TimePeriodFrom $periodFrom -TimePeriodTo $periodTo -DatasetGranularity 'None' `
            -DatasetAggregation @{ totalCost = @{ name = 'PreTaxCost'; function = 'Sum' } } `
            -DatasetGrouping @(@{ type = 'Dimension'; name = $GroupBy })
    }

    # The response is Row/Column arrays: locate each field's index by column name.
    $columnNames = @($response.Column | ForEach-Object { [string]$_.Name })
    $costIndex = $null
    $dimensionIndex = $null
    $currencyIndex = $null
    for ($i = 0; $i -lt $columnNames.Count; $i++) {
        if ($columnNames[$i] -in @('PreTaxCost', 'totalCost', 'Cost')) { $costIndex = $i }
        elseif ($columnNames[$i] -eq $GroupBy) { $dimensionIndex = $i }
        elseif ($columnNames[$i] -eq 'Currency') { $currencyIndex = $i }
    }
    if ($null -eq $costIndex -or $null -eq $dimensionIndex) {
        throw "Unexpected Cost Management response columns: $($columnNames -join ', ')"
    }

    $costRows = @(foreach ($row in @($response.Row)) {
            [pscustomobject]@{
                GroupBy  = $GroupBy
                Name     = [string]$row[$dimensionIndex]
                CostUsd  = [Math]::Round([double]$row[$costIndex], 2)
                Currency = if ($null -ne $currencyIndex) { [string]$row[$currencyIndex] } else { 'USD' }
            }
        })
    $costRows = @($costRows | Sort-Object -Property CostUsd -Descending)

    $totalCost = [Math]::Round((($costRows | Measure-Object -Property CostUsd -Sum).Sum ?? 0), 2)
    Write-ToolkitLog -Message "$($costRows.Count) cost row(s); total $totalCost" -Data @{
        groupBy  = $GroupBy
        totalUsd = $totalCost
    }

    $costRows

    if ($costRows.Count -gt 0) {
        $exportParams = @{ InputObject = $costRows; Name = 'monthly-cost-report'; OutputDirectory = $OutputDirectory }
        $null = if ($ExportFormat -eq 'Csv') { Export-ToolkitCsv @exportParams } else { Export-ToolkitJson @exportParams }
    }
    else {
        Write-ToolkitLog -Level Warning -Message 'No cost rows returned - nothing exported'
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
