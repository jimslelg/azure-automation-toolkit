#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Monitor

<#
.SYNOPSIS
    Applies a diagnostic setting sending all logs and metrics to a Log Analytics workspace.
.DESCRIPTION
    For each target resource, discovers the supported diagnostic categories with
    Get-AzDiagnosticSettingCategory and creates (or overwrites) a diagnostic setting
    that routes all logs - via the 'allLogs' category group where the resource supports
    it, otherwise per log category - plus the 'AllMetrics' metric category to the given
    Log Analytics workspace. Per-resource error isolation (exit 3 on partial failure),
    -WhatIf support, and one result object per resource on the pipeline.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER TargetResourceId
    One or more full resource IDs to apply the diagnostic setting to.
.PARAMETER WorkspaceResourceId
    Full resource ID of the destination Log Analytics workspace.
.PARAMETER SettingName
    Name of the diagnostic setting. Default 'toolkit-diagnostics'.
.EXAMPLE
    ./Set-DiagnosticSettings.ps1 -TargetResourceId $keyVault.ResourceId `
        -WorkspaceResourceId $workspace.ResourceId -WhatIf

    Shows which diagnostic setting would be applied without changing anything.
.EXAMPLE
    ./Set-DiagnosticSettings.ps1 -TargetResourceId $appIds -WorkspaceResourceId $workspace.ResourceId

    Applies the 'toolkit-diagnostics' setting to every resource ID in $appIds.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Monitoring Contributor on the target resources and the workspace.
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
    [string[]]$TargetResourceId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$WorkspaceResourceId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$SettingName = 'toolkit-diagnostics'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'AzToolkit.Common.psd1') -Force

$exitCode = 0
try {
    $null = Initialize-ToolkitLog -ScriptName $MyInvocation.MyCommand.Name
    $null = Connect-ToolkitAzure -SubscriptionId $SubscriptionId

    Write-ToolkitLog -Message "Applying diagnostic setting '$SettingName' to $($TargetResourceId.Count) resource(s)" -Data @{
        workspace = $WorkspaceResourceId
    }

    $failures = 0
    $results = foreach ($resourceId in $TargetResourceId) {
        $resourceName = ($resourceId -split '/')[-1]
        try {
            $categories = @(Invoke-WithRetry -OperationName "Get categories for $resourceName" -ScriptBlock {
                    Get-AzDiagnosticSettingCategory -ResourceId $resourceId
                })
            $logCategories = @($categories | Where-Object { $_.CategoryType -eq 'Logs' })
            $metricCategories = @($categories | Where-Object { $_.CategoryType -eq 'Metrics' })

            $supportsAllLogs = [bool]($logCategories | Where-Object { $_.CategoryGroup -contains 'allLogs' })
            $logSettings = @()
            if ($supportsAllLogs) {
                $logSettings = @(New-AzDiagnosticSettingLogSettingsObject -CategoryGroup 'allLogs' -Enabled $true)
            }
            elseif ($logCategories.Count -gt 0) {
                $logSettings = @($logCategories | ForEach-Object {
                        New-AzDiagnosticSettingLogSettingsObject -Category $_.Name -Enabled $true
                    })
            }

            $metricSettings = @()
            if ($metricCategories.Count -gt 0) {
                $metricSettings = @(New-AzDiagnosticSettingMetricSettingsObject -Category 'AllMetrics' -Enabled $true)
            }

            if ($logSettings.Count -eq 0 -and $metricSettings.Count -eq 0) {
                Write-ToolkitLog -Level Warning -Message "Resource '$resourceName' exposes no diagnostic categories - skipping"
                continue
            }

            $logMode = if ($supportsAllLogs) { 'allLogs' } elseif ($logSettings.Count -gt 0) { 'perCategory' } else { 'none' }
            if (-not $PSCmdlet.ShouldProcess($resourceId, "Apply diagnostic setting '$SettingName' (logs: $logMode; metrics: $($metricSettings.Count -gt 0))")) {
                continue
            }

            $settingParams = @{
                Name        = $SettingName
                ResourceId  = $resourceId
                WorkspaceId = $WorkspaceResourceId
            }
            if ($logSettings.Count -gt 0) { $settingParams.Log = $logSettings }
            if ($metricSettings.Count -gt 0) { $settingParams.Metric = $metricSettings }

            $null = Invoke-WithRetry -OperationName "Apply diagnostics to $resourceName" -ScriptBlock {
                New-AzDiagnosticSetting @settingParams
            }
            Write-ToolkitLog -Message 'Diagnostic setting applied' -Data @{
                resource = $resourceName
                logMode  = $logMode
            }
            [pscustomobject]@{
                ResourceId          = $resourceId
                ResourceName        = $resourceName
                SettingName         = $SettingName
                WorkspaceResourceId = $WorkspaceResourceId
                LogMode             = $logMode
                LogCategoryCount    = $logCategories.Count
                MetricsEnabled      = $metricSettings.Count -gt 0
                Status              = 'Applied'
            }
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Failed to apply diagnostics to '$resourceName'" -ErrorRecord $_
            [pscustomobject]@{
                ResourceId          = $resourceId
                ResourceName        = $resourceName
                SettingName         = $SettingName
                WorkspaceResourceId = $WorkspaceResourceId
                LogMode             = $null
                LogCategoryCount    = 0
                MetricsEnabled      = $false
                Status              = 'Failed'
            }
        }
    }

    if ($failures -gt 0 -and $failures -lt $TargetResourceId.Count) { $exitCode = 3 }
    elseif ($failures -gt 0) { throw "All $failures diagnostic setting operation(s) failed." }

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
