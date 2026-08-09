#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.PolicyInsights

<#
.SYNOPSIS
    Reports non-compliant Azure Policy state, summarized per policy assignment.
.DESCRIPTION
    Queries Azure Policy compliance state for non-compliant resources and summarizes
    the results per policy assignment: assignment name, definition name, and the
    number of non-compliant resources. With -Detailed, emits one row per non-compliant
    resource (assignment, definition, resource ID, resource type) instead. Read-only
    and exportable with -ExportPath.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER Detailed
    Emit one row per non-compliant resource instead of the per-assignment summary.
.PARAMETER ExportPath
    Optional directory to export results to (created if missing; timestamped filename).
.PARAMETER ExportFormat
    Export format when -ExportPath is supplied. Csv (default) or Json.
.EXAMPLE
    ./Get-PolicyComplianceReport.ps1

    Emits the per-assignment summary of non-compliant resource counts.
.EXAMPLE
    ./Get-PolicyComplianceReport.ps1 -Detailed -ExportPath ./output -ExportFormat Json

    Lists every non-compliant resource and exports the detail rows as JSON.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Reader on the target scope (Resource Policy Reader recommended).
    Exit codes: 0 success, 1 general failure, 2 auth failure,
                4 invalid parameters/configuration.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter()]
    [switch]$Detailed,

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

    $states = @(Invoke-WithRetry -OperationName 'Query policy states' -ScriptBlock {
            Get-AzPolicyState -Filter "ComplianceState eq 'NonCompliant'"
        })
    Write-ToolkitLog -Message "$($states.Count) non-compliant policy state record(s) returned"

    $groups = @($states | Group-Object -Property PolicyAssignmentName, PolicyDefinitionName)

    $report = if ($Detailed) {
        foreach ($state in $states) {
            [pscustomobject]@{
                AssignmentName = $state.PolicyAssignmentName
                DefinitionName = $state.PolicyDefinitionName
                ResourceId     = $state.ResourceId
                ResourceType   = $state.ResourceType
                ResourceGroup  = $state.ResourceGroup
            }
        }
    }
    else {
        foreach ($group in $groups) {
            $resourceCount = @($group.Group | Select-Object -ExpandProperty ResourceId -Unique).Count
            [pscustomobject]@{
                AssignmentName            = $group.Group[0].PolicyAssignmentName
                DefinitionName            = $group.Group[0].PolicyDefinitionName
                NonCompliantResourceCount = $resourceCount
            }
        }
    }

    $report = @($report | Sort-Object -Property AssignmentName, DefinitionName)
    Write-ToolkitLog -Message "$($groups.Count) policy assignment(s) with non-compliant resources" -Data @{
        detailed = [bool]$Detailed
        rows     = $report.Count
    }

    $report

    if ($ExportPath -and $report.Count -gt 0) {
        $exportName = if ($Detailed) { 'policy-compliance-detail' } else { 'policy-compliance-summary' }
        $exportParams = @{ InputObject = $report; Name = $exportName; OutputDirectory = $ExportPath }
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
