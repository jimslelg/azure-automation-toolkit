#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources

<#
.SYNOPSIS
    Summarizes missing required tags per resource group and tag key.
.DESCRIPTION
    Scans all resources in scope (optionally one resource group), finds those missing
    required tag keys, and aggregates the gaps into one row per resource group and tag:
    how many resources miss that tag and up to three example resource names. The
    required tag list comes from -RequiredTags, falling back to the 'requiredTags' key
    of the 'governance' config section, then to Environment/Owner/CostCenter. Read-only
    and exportable with -ExportPath - the remediation worklist companion to
    Get-ResourceTagAudit.ps1.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ResourceGroupName
    Optional resource group to limit the scan; the whole subscription otherwise.
.PARAMETER RequiredTags
    Tag keys every resource must carry. Defaults to the governance config section's
    requiredTags value, or Environment/Owner/CostCenter when config is missing.
.PARAMETER ExportPath
    Optional directory to export results to (created if missing; timestamped filename).
.PARAMETER ExportFormat
    Export format when -ExportPath is supplied. Csv (default) or Json.
.EXAMPLE
    ./Get-MissingTagsReport.ps1

    Reports missing-tag counts per resource group across the subscription.
.EXAMPLE
    ./Get-MissingTagsReport.ps1 -RequiredTags Environment, CostCenter -ExportPath ./output

    Reports gaps for two specific tags and exports the summary as CSV.
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
    Write-ToolkitLog -Message "Reporting against required tags: $($RequiredTags -join ', ')"

    $null = Connect-ToolkitAzure -SubscriptionId $SubscriptionId

    $getResourceParams = @{}
    if ($ResourceGroupName) {
        $getResourceParams.ResourceGroupName = $ResourceGroupName
    }
    $resources = @(Invoke-WithRetry -OperationName 'List resources' -ScriptBlock {
            Get-AzResource @getResourceParams
        })
    Write-ToolkitLog -Message "Scanning $($resources.Count) resource(s) for missing tags"

    $gaps = foreach ($resource in $resources) {
        $tagKeys = @(if ($resource.Tags) { $resource.Tags.Keys })
        foreach ($tag in $RequiredTags) {
            if ($tagKeys -notcontains $tag) {
                [pscustomobject]@{
                    ResourceGroup = $resource.ResourceGroupName
                    TagName       = $tag
                    ResourceName  = $resource.Name
                }
            }
        }
    }

    $report = @($gaps | Group-Object -Property ResourceGroup, TagName | ForEach-Object {
            $examples = @($_.Group | Select-Object -First 3 -ExpandProperty ResourceName)
            [pscustomobject]@{
                ResourceGroup    = $_.Group[0].ResourceGroup
                TagName          = $_.Group[0].TagName
                MissingCount     = $_.Count
                ExampleResources = $examples -join '; '
            }
        } | Sort-Object -Property ResourceGroup, TagName)

    Write-ToolkitLog -Message "$($report.Count) resource-group/tag gap(s) found across $(@($gaps).Count) missing tag instance(s)"
    $report

    if ($ExportPath -and $report.Count -gt 0) {
        $exportParams = @{ InputObject = $report; Name = 'missing-tags-report'; OutputDirectory = $ExportPath }
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
