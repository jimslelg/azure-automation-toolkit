#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Compute, Az.Monitor

<#
.SYNOPSIS
    Finds running VMs whose average CPU stayed below a threshold - right-sizing candidates.
.DESCRIPTION
    Queries Azure Monitor 'Percentage CPU' metrics for every running VM in scope over a
    lookback window and reports VMs whose average CPU is below the threshold. Read-only:
    the output feeds right-sizing or shutdown decisions (pipe candidates into
    Stop-AzureVm.ps1 or Set-VmSize.ps1). Emits one object per idle VM and can export
    the report with -ExportPath.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ResourceGroupName
    Optional resource group to limit the scan; the whole subscription otherwise.
.PARAMETER CpuThresholdPercent
    Average CPU percentage below which a VM counts as idle (default 5).
.PARAMETER LookbackDays
    Days of metric history to evaluate (default 14).
.PARAMETER ExportPath
    Optional directory to export results to (created if missing; timestamped filename).
.PARAMETER ExportFormat
    Export format when -ExportPath is supplied. Csv (default) or Json.
.EXAMPLE
    ./Get-IdleVms.ps1 -CpuThresholdPercent 5 -LookbackDays 14

    Reports subscription-wide idle VMs over the last two weeks.
.EXAMPLE
    ./Get-IdleVms.ps1 -ResourceGroupName rg-app-dev -ExportPath ./output -ExportFormat Json

    Scans one resource group and exports the findings as JSON.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Reader + Monitoring Reader on the target scope.
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure
                (some VMs' metrics unavailable), 4 invalid parameters/configuration.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$ResourceGroupName,

    [Parameter()]
    [ValidateRange(1, 100)]
    [int]$CpuThresholdPercent = 5,

    [Parameter()]
    [ValidateRange(1, 90)]
    [int]$LookbackDays = 14,

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

    $getVmParams = @{ Status = $true }
    if ($ResourceGroupName) {
        $getVmParams.ResourceGroupName = $ResourceGroupName
    }
    $runningVms = @(Invoke-WithRetry -OperationName 'List VMs' -ScriptBlock { Get-AzVM @getVmParams } |
            Where-Object PowerState -EQ 'VM running')

    Write-ToolkitLog -Message "Evaluating $($runningVms.Count) running VM(s) over the last $LookbackDays day(s)"

    $endTime = Get-Date
    $startTime = $endTime.AddDays(-$LookbackDays)
    $failures = 0

    $idleVms = foreach ($vm in $runningVms) {
        try {
            $metrics = Invoke-WithRetry -OperationName "Metrics for $($vm.Name)" -ScriptBlock {
                Get-AzMetric -ResourceId $vm.Id -MetricName 'Percentage CPU' `
                    -StartTime $startTime -EndTime $endTime `
                    -TimeGrain ([timespan]::FromHours(1)) -AggregationType Average `
                    -WarningAction SilentlyContinue
            }
            $samples = @($metrics.Data | Where-Object { $null -ne $_.Average })
            if ($samples.Count -eq 0) {
                Write-ToolkitLog -Level Warning -Message "No CPU samples for '$($vm.Name)' - skipping"
                continue
            }

            $averageCpu = ($samples.Average | Measure-Object -Average).Average
            $maximumCpu = ($samples.Average | Measure-Object -Maximum).Maximum
            if ($averageCpu -lt $CpuThresholdPercent) {
                Write-ToolkitLog -Message 'Idle VM found' -Data @{
                    vm     = $vm.Name
                    avgCpu = [Math]::Round($averageCpu, 2)
                }
                [pscustomobject]@{
                    Name              = $vm.Name
                    ResourceGroupName = $vm.ResourceGroupName
                    Location          = $vm.Location
                    VmSize            = $vm.HardwareProfile.VmSize
                    PowerState        = $vm.PowerState
                    AverageCpuPercent = [Math]::Round($averageCpu, 2)
                    MaximumCpuPercent = [Math]::Round($maximumCpu, 2)
                    LookbackDays      = $LookbackDays
                    SampleCount       = $samples.Count
                }
            }
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Failed to evaluate '$($vm.Name)'" -ErrorRecord $_
        }
    }

    $idleVms = @($idleVms)
    if ($failures -gt 0 -and $failures -lt $runningVms.Count) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $runningVms.Count -gt 0) { throw "Metric evaluation failed for all $failures VM(s)." }

    Write-ToolkitLog -Message "$($idleVms.Count) idle VM(s) below $CpuThresholdPercent% average CPU"
    $idleVms

    if ($ExportPath -and $idleVms.Count -gt 0) {
        $exportParams = @{ InputObject = $idleVms; Name = 'idle-vms'; OutputDirectory = $ExportPath }
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
