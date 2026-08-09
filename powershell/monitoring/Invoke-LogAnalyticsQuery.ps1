#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.OperationalInsights

<#
.SYNOPSIS
    Runs a KQL query against a Log Analytics workspace and emits the result rows.
.DESCRIPTION
    Executes a Kusto query - supplied inline via -Query or from a .kql file via
    -QueryFile (exactly one of the two is required) - against the given workspace over
    a bounded timespan using Invoke-AzOperationalInsightsQuery. Result rows are emitted
    as objects on the pipeline and can optionally be exported with -ExportPath. The
    query execution is gated by ShouldProcess, so -WhatIf shows what would run.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER WorkspaceId
    Workspace (customer) ID - the GUID of the Log Analytics workspace.
.PARAMETER Query
    Inline KQL query text. Mutually exclusive with -QueryFile.
.PARAMETER QueryFile
    Path to a .kql file containing the query. Mutually exclusive with -Query.
.PARAMETER TimespanHours
    Query timespan in hours, counted back from now (default 24).
.PARAMETER ExportPath
    Optional directory to export results to (created if missing; timestamped filename).
.PARAMETER ExportFormat
    Export format when -ExportPath is supplied. Csv (default) or Json.
.EXAMPLE
    ./Invoke-LogAnalyticsQuery.ps1 -WorkspaceId 00000000-0000-0000-0000-000000000000 `
        -Query 'Heartbeat | summarize count() by Computer'

    Runs an inline query over the last 24 hours and emits the rows.
.EXAMPLE
    ./Invoke-LogAnalyticsQuery.ps1 -WorkspaceId $workspace.CustomerId `
        -QueryFile ./queries/failed-signins.kql -TimespanHours 72 -ExportPath ./output

    Runs a saved query over three days and exports the results as CSV.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Log Analytics Reader on the workspace.
    Exit codes: 0 success, 1 general failure, 2 auth failure,
                4 invalid parameters/configuration.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$WorkspaceId,

    [Parameter()]
    [string]$Query,

    [Parameter()]
    [string]$QueryFile,

    [Parameter()]
    [ValidateRange(1, 2160)]
    [int]$TimespanHours = 24,

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

    if ((-not $Query -and -not $QueryFile) -or ($Query -and $QueryFile)) {
        $exception = [System.ArgumentException]::new('Provide exactly one of -Query or -QueryFile.')
        throw [System.Management.Automation.ErrorRecord]::new(
            $exception, 'AzToolkit.ConfigurationInvalid.QueryInput',
            [System.Management.Automation.ErrorCategory]::InvalidArgument, $null)
    }
    if ($QueryFile) {
        if (-not (Test-Path -Path $QueryFile -PathType Leaf)) {
            $exception = [System.IO.FileNotFoundException]::new("Query file not found: $QueryFile")
            throw [System.Management.Automation.ErrorRecord]::new(
                $exception, 'AzToolkit.ConfigurationInvalid.QueryFileMissing',
                [System.Management.Automation.ErrorCategory]::ObjectNotFound, $QueryFile)
        }
        $Query = Get-Content -Path $QueryFile -Raw
        Write-ToolkitLog -Message "Loaded query from '$QueryFile'"
    }

    $null = Connect-ToolkitAzure -SubscriptionId $SubscriptionId

    $rows = @()
    if ($PSCmdlet.ShouldProcess($WorkspaceId, 'Run KQL query')) {
        Write-ToolkitLog -Message 'Running Log Analytics query' -Data @{
            workspaceId   = $WorkspaceId
            timespanHours = $TimespanHours
        }
        $response = Invoke-WithRetry -OperationName 'Log Analytics query' -ScriptBlock {
            Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $Query `
                -Timespan (New-TimeSpan -Hours $TimespanHours)
        }
        $rows = @($response.Results)
        Write-ToolkitLog -Message "Query returned $($rows.Count) row(s)"
    }

    $rows

    if ($ExportPath -and $rows.Count -gt 0) {
        $exportParams = @{ InputObject = $rows; Name = 'log-analytics-query'; OutputDirectory = $ExportPath }
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
