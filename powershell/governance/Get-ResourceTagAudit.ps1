#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources

<#
.SYNOPSIS
    Audits every resource in scope for required tags and reports compliance.
.DESCRIPTION
    Lists all resources (optionally limited to one resource group) and checks each one
    for the required tag keys. The required tag list comes from -RequiredTags, falling
    back to the 'requiredTags' key of the 'governance' config section, and finally to
    Environment/Owner/CostCenter when no configuration exists. Read-only; emits one
    object per resource with its missing tags and a compliance flag, logs an overall
    compliance percentage, and can export the report with -ExportPath.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ResourceGroupName
    Optional resource group to limit the audit; the whole subscription otherwise.
.PARAMETER RequiredTags
    Tag keys every resource must carry. Defaults to the governance config section's
    requiredTags value, or Environment/Owner/CostCenter when config is missing.
.PARAMETER ExportPath
    Optional directory to export results to (created if missing; timestamped filename).
.PARAMETER ExportFormat
    Export format when -ExportPath is supplied. Csv (default) or Json.
.EXAMPLE
    ./Get-ResourceTagAudit.ps1

    Audits the whole subscription against the configured required tags.
.EXAMPLE
    ./Get-ResourceTagAudit.ps1 -ResourceGroupName rg-app-prod -RequiredTags Environment, Owner `
        -ExportPath ./output -ExportFormat Json

    Audits one resource group against an explicit tag list and exports the findings.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Reader on the target scope.
    Exit codes: 0 success, 1 general failure, 2 auth failure,
                4 invalid parameters/configuration.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$ResourceGroupName,

    [Parameter()]
    [string[]]$RequiredTags,

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

    if (-not $RequiredTags -or $RequiredTags.Count -eq 0) {
        try {
            $governanceConfig = Get-ToolkitConfig -Section governance
            $RequiredTags = @($governanceConfig.requiredTags)
        }
        catch {
            Write-ToolkitLog -Level Warning -Message 'Governance config unavailable; using built-in default tag list'
        }
        if (-not $RequiredTags -or $RequiredTags.Count -eq 0) {
            $RequiredTags = @('Environment', 'Owner', 'CostCenter')
        }
    }
    Write-ToolkitLog -Message "Auditing against required tags: $($RequiredTags -join ', ')"

    $null = Connect-ToolkitAzure -SubscriptionId $SubscriptionId

    $getResourceParams = @{}
    if ($ResourceGroupName) {
        $getResourceParams.ResourceGroupName = $ResourceGroupName
    }
    $resources = @(Invoke-WithRetry -OperationName 'List resources' -ScriptBlock {
            Get-AzResource @getResourceParams
        })
    Write-ToolkitLog -Message "Auditing $($resources.Count) resource(s)"

    $audit = foreach ($resource in $resources) {
        $tagKeys = @(if ($resource.Tags) { $resource.Tags.Keys })
        $missing = @($RequiredTags | Where-Object { $tagKeys -notcontains $_ })
        [pscustomobject]@{
            Name              = $resource.Name
            ResourceType      = $resource.ResourceType
            ResourceGroupName = $resource.ResourceGroupName
            Location          = $resource.Location
            MissingTags       = $missing -join ';'
            MissingTagCount   = $missing.Count
            Compliant         = $missing.Count -eq 0
        }
    }

    $audit = @($audit)
    $compliantCount = @($audit | Where-Object Compliant).Count
    $compliancePercent = if ($audit.Count -gt 0) { [Math]::Round(($compliantCount / $audit.Count) * 100, 1) } else { 100 }
    Write-ToolkitLog -Message "Tag compliance: $compliancePercent% ($compliantCount of $($audit.Count) resource(s) compliant)" -Data @{
        requiredTags      = $RequiredTags -join ','
        compliancePercent = $compliancePercent
    }

    $audit

    if ($ExportPath -and $audit.Count -gt 0) {
        $exportParams = @{ InputObject = $audit; Name = 'resource-tag-audit'; OutputDirectory = $ExportPath }
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
