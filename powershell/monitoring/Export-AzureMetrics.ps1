#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Monitor

<#
.SYNOPSIS
    Exports Azure Monitor metric time series for a resource to CSV or JSON.
.DESCRIPTION
    Queries one or more metrics for a single resource over a lookback window and
    flattens the time series into one row per timestamp per metric (resource ID,
    metric, timestamp, value, unit). Read-only; emits the rows to the pipeline and
    always writes a timestamped export file to the output directory.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ResourceId
    Full resource ID of the resource whose metrics are exported.
.PARAMETER MetricNames
    One or more metric names to export (e.g. 'Percentage CPU', 'Disk Read Bytes').
.PARAMETER LookbackHours
    Hours of metric history to export (default 24).
.PARAMETER TimeGrainMinutes
    Sampling interval in minutes: 1, 5, 15, 30, or 60. Default 5.
.PARAMETER AggregationType
    Aggregation applied per time grain: Average (default), Total, Maximum,
    Minimum, or Count.
.PARAMETER OutputDirectory
    Directory for the export file (created if missing). Defaults to ./output.
.PARAMETER ExportFormat
    Csv (default) or Json.
.EXAMPLE
    ./Export-AzureMetrics.ps1 -ResourceId $vm.Id -MetricNames 'Percentage CPU'

    Exports 24 hours of 5-minute average CPU samples to ./output.
.EXAMPLE
    ./Export-AzureMetrics.ps1 -ResourceId $storage.Id -MetricNames 'Ingress', 'Egress' `
        -LookbackHours 72 -TimeGrainMinutes 60 -AggregationType Total -ExportFormat Json

    Exports three days of hourly ingress/egress totals as JSON.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Monitoring Reader on the target resource.
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure
                (some metrics unavailable), 4 invalid parameters/configuration.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string[]]$MetricNames,

    [Parameter()]
    [ValidateRange(1, 2160)]
    [int]$LookbackHours = 24,

    [Parameter()]
    [ValidateSet(1, 5, 15, 30, 60)]
    [int]$TimeGrainMinutes = 5,

    [Parameter()]
    [ValidateSet('Average', 'Total', 'Maximum', 'Minimum', 'Count')]
    [string]$AggregationType = 'Average',

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

    $endTime = Get-Date
    $startTime = $endTime.AddHours(-$LookbackHours)
    Write-ToolkitLog -Message "Exporting $($MetricNames.Count) metric(s) over the last $LookbackHours hour(s)" -Data @{
        resourceId  = $ResourceId
        aggregation = $AggregationType
        grain       = $TimeGrainMinutes
    }

    $failures = 0
    $rows = foreach ($metricName in $MetricNames) {
        try {
            $metrics = Invoke-WithRetry -OperationName "Metric $metricName" -ScriptBlock {
                Get-AzMetric -ResourceId $ResourceId -MetricName $metricName `
                    -StartTime $startTime -EndTime $endTime `
                    -TimeGrain ([timespan]::FromMinutes($TimeGrainMinutes)) `
                    -AggregationType $AggregationType -WarningAction SilentlyContinue
            }
            foreach ($metric in @($metrics)) {
                $samples = @($metric.Data | Where-Object { $null -ne $_.$AggregationType })
                Write-ToolkitLog -Message "Metric '$metricName': $($samples.Count) sample(s)"
                foreach ($sample in $samples) {
                    [pscustomobject]@{
                        ResourceId  = $ResourceId
                        Metric      = $metric.Name.Value
                        Timestamp   = $sample.TimeStamp
                        Value       = $sample.$AggregationType
                        Unit        = [string]$metric.Unit
                        Aggregation = $AggregationType
                    }
                }
            }
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Failed to retrieve metric '$metricName'" -ErrorRecord $_
        }
    }

    $rows = @($rows)
    if ($failures -gt 0 -and $failures -lt $MetricNames.Count) { $exitCode = 3 }
    elseif ($failures -gt 0) { throw "All $failures metric quer(ies) failed." }

    Write-ToolkitLog -Message "Collected $($rows.Count) data point(s)"
    $rows

    if ($rows.Count -gt 0) {
        $exportParams = @{ InputObject = $rows; Name = 'azure-metrics'; OutputDirectory = $OutputDirectory }
        $null = if ($ExportFormat -eq 'Csv') { Export-ToolkitCsv @exportParams } else { Export-ToolkitJson @exportParams }
    }
    else {
        Write-ToolkitLog -Level Warning -Message 'No metric data points in the window; nothing exported'
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
