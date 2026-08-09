#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Monitor

<#
.SYNOPSIS
    Creates an Azure Monitor metric alert rule (v2) against a target resource.
.DESCRIPTION
    Builds a single-metric criteria with New-AzMetricAlertRuleV2Criteria and creates
    the alert rule with Add-AzMetricAlertRuleV2 in the given resource group. Optionally
    wires the rule to an existing action group. Supports -WhatIf; emits one result
    object describing the created rule.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER AlertName
    Name of the metric alert rule to create.
.PARAMETER ResourceGroupName
    Resource group in which the alert rule resource is created.
.PARAMETER TargetResourceId
    Full resource ID of the resource the alert monitors.
.PARAMETER MetricName
    Metric to evaluate (e.g. 'Percentage CPU').
.PARAMETER Operator
    Comparison operator for the threshold. GreaterThan (default), LessThan,
    GreaterThanOrEqual, or LessThanOrEqual.
.PARAMETER Threshold
    Numeric threshold the metric is compared against.
.PARAMETER Severity
    Alert severity 0 (critical) through 4 (verbose). Default 3.
.PARAMETER WindowMinutes
    Aggregation window in minutes: 1, 5, 15, 30, or 60. Default 5.
.PARAMETER EvaluationFrequencyMinutes
    How often the rule is evaluated, in minutes: 1, 5, 15, 30, or 60. Default 5.
.PARAMETER ActionGroupId
    Optional resource ID of an action group to notify when the alert fires.
.EXAMPLE
    ./New-AzureMonitorAlert.ps1 -AlertName cpu-high -ResourceGroupName rg-monitoring `
        -TargetResourceId /subscriptions/xxx/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/web-01 `
        -MetricName 'Percentage CPU' -Operator GreaterThan -Threshold 90 -Severity 2

    Creates a severity-2 alert that fires when average CPU exceeds 90 percent.
.EXAMPLE
    ./New-AzureMonitorAlert.ps1 -AlertName mem-low -ResourceGroupName rg-monitoring `
        -TargetResourceId $vm.Id -MetricName 'Available Memory Bytes' -Operator LessThan `
        -Threshold 500000000 -ActionGroupId $actionGroup.Id -WhatIf

    Previews the alert rule creation without applying it.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Monitoring Contributor on the target scope.
    Exit codes: 0 success, 1 general failure, 2 auth failure,
                4 invalid parameters/configuration.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$AlertName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetResourceId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$MetricName,

    [Parameter()]
    [ValidateSet('GreaterThan', 'LessThan', 'GreaterThanOrEqual', 'LessThanOrEqual')]
    [string]$Operator = 'GreaterThan',

    [Parameter(Mandatory)]
    [double]$Threshold,

    [Parameter()]
    [ValidateRange(0, 4)]
    [int]$Severity = 3,

    [Parameter()]
    [ValidateSet(1, 5, 15, 30, 60)]
    [int]$WindowMinutes = 5,

    [Parameter()]
    [ValidateSet(1, 5, 15, 30, 60)]
    [int]$EvaluationFrequencyMinutes = 5,

    [Parameter()]
    [string]$ActionGroupId
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'AzToolkit.Common.psd1') -Force

$exitCode = 0
try {
    $null = Initialize-ToolkitLog -ScriptName $MyInvocation.MyCommand.Name
    $null = Connect-ToolkitAzure -SubscriptionId $SubscriptionId

    Write-ToolkitLog -Message 'Building metric alert criteria' -Data @{
        metric    = $MetricName
        operator  = $Operator
        threshold = $Threshold
    }
    $criteria = New-AzMetricAlertRuleV2Criteria -MetricName $MetricName `
        -TimeAggregation Average -Operator $Operator -Threshold $Threshold

    $ruleParams = @{
        Name              = $AlertName
        ResourceGroupName = $ResourceGroupName
        TargetResourceId  = $TargetResourceId
        Condition         = $criteria
        Severity          = $Severity
        WindowSize        = [timespan]::FromMinutes($WindowMinutes)
        Frequency         = [timespan]::FromMinutes($EvaluationFrequencyMinutes)
    }
    if ($ActionGroupId) {
        $ruleParams.ActionGroupId = @($ActionGroupId)
    }

    $action = "Create metric alert rule '$AlertName' ($MetricName $Operator $Threshold)"
    if ($PSCmdlet.ShouldProcess($TargetResourceId, $action)) {
        $rule = Invoke-WithRetry -OperationName "Create alert rule $AlertName" -ScriptBlock {
            Add-AzMetricAlertRuleV2 @ruleParams
        }
        Write-ToolkitLog -Message 'Metric alert rule created' -Data @{
            rule          = $AlertName
            resourceGroup = $ResourceGroupName
            severity      = $Severity
        }
        [pscustomobject]@{
            AlertName                  = $AlertName
            ResourceGroupName          = $ResourceGroupName
            TargetResourceId           = $TargetResourceId
            MetricName                 = $MetricName
            Operator                   = $Operator
            Threshold                  = $Threshold
            Severity                   = $Severity
            WindowMinutes              = $WindowMinutes
            EvaluationFrequencyMinutes = $EvaluationFrequencyMinutes
            ActionGroupId              = $ActionGroupId
            RuleId                     = $rule.Id
            Enabled                    = $true
        }
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
