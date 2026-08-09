#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.ResourceGraph

<#
.SYNOPSIS
    Runs a caller-supplied Azure Resource Graph KQL query and emits the rows.
.DESCRIPTION
    Executes an arbitrary Resource Graph query supplied either inline via -Query or
    from a .kql file via -QueryFile (exactly one of the two is required; the script
    exits 4 otherwise). Handles paging with -First 1000 plus SkipToken loops, emits
    one object per result row, and optionally exports the rows with -ExportPath.
    Query execution is gated by ShouldProcess, so -WhatIf previews the query text
    without contacting Resource Graph.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER Query
    Inline KQL Resource Graph query text. Mutually exclusive with -QueryFile.
.PARAMETER QueryFile
    Path to a .kql file containing the query. Mutually exclusive with -Query.
.PARAMETER ExportPath
    Optional directory to export results to (created if missing; timestamped filename).
.PARAMETER ExportFormat
    Export format when -ExportPath is supplied. Csv (default) or Json.
.EXAMPLE
    ./Invoke-ResourceGraphReport.ps1 -Query "Resources | summarize count() by type | order by count_ desc"

    Runs an inline query and emits the aggregated rows.
.EXAMPLE
    ./Invoke-ResourceGraphReport.ps1 -QueryFile ./queries/orphaned-nics.kql -ExportPath ./output

    Runs the query stored in a .kql file and exports the rows as CSV.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Reader on the target scope.
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure,
                4 invalid parameters/configuration (including neither/both of
                -Query and -QueryFile supplied).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Query,

    [Parameter()]
    [ValidatePattern('\.kql$')]
    [string]$QueryFile,

    [Parameter()]
    [string]$ExportPath,

    [Parameter()]
    [ValidateSet('Csv', 'Json')]
    [string]$ExportFormat = 'Csv'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'AzToolkit.Common.psd1') -Force

function Get-GraphQueryResult {
    <#
    .SYNOPSIS
        Runs a Resource Graph query and follows SkipToken paging (-First 1000 per page).
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Query,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OperationName
    )

    $rows = [System.Collections.Generic.List[pscustomobject]]::new()
    $skipToken = $null
    do {
        $graphParams = @{ Query = $Query; First = 1000 }
        if ($skipToken) {
            $graphParams.SkipToken = $skipToken
        }
        $page = Invoke-WithRetry -OperationName $OperationName -ScriptBlock { Search-AzGraph @graphParams }
        if ($null -eq $page) {
            break
        }
        $pageRows = if ($null -ne $page.PSObject.Properties['Data']) { @($page.Data) } else { @($page) }
        foreach ($row in $pageRows) {
            $rows.Add([pscustomobject]$row)
        }
        $skipToken = if ($null -ne $page.PSObject.Properties['SkipToken']) { $page.SkipToken } else { $null }
    } while (-not [string]::IsNullOrEmpty($skipToken))
    return , $rows
}

$exitCode = 0
try {
    $null = Initialize-ToolkitLog -ScriptName $MyInvocation.MyCommand.Name

    # Exactly one query source is required - anything else is a configuration error (exit 4).
    $querySources = @($PSBoundParameters.Keys | Where-Object { $_ -in @('Query', 'QueryFile') })
    if ($querySources.Count -ne 1) {
        $exception = [System.ArgumentException]::new('Provide exactly one of -Query or -QueryFile.')
        throw [System.Management.Automation.ErrorRecord]::new(
            $exception,
            'AzToolkit.ConfigurationInvalid.QuerySource',
            [System.Management.Automation.ErrorCategory]::InvalidArgument,
            $null)
    }

    $queryText = $Query
    if ($QueryFile) {
        if (-not (Test-Path -Path $QueryFile -PathType Leaf)) {
            $exception = [System.IO.FileNotFoundException]::new("Query file not found: $QueryFile")
            throw [System.Management.Automation.ErrorRecord]::new(
                $exception,
                'AzToolkit.ConfigurationInvalid.QueryFileMissing',
                [System.Management.Automation.ErrorCategory]::ObjectNotFound,
                $QueryFile)
        }
        $queryText = Get-Content -Path $QueryFile -Raw
    }
    if ([string]::IsNullOrWhiteSpace($queryText)) {
        $exception = [System.ArgumentException]::new('The supplied query is empty.')
        throw [System.Management.Automation.ErrorRecord]::new(
            $exception,
            'AzToolkit.ConfigurationInvalid.QueryEmpty',
            [System.Management.Automation.ErrorCategory]::InvalidArgument,
            $null)
    }

    $null = Connect-ToolkitAzure -SubscriptionId $SubscriptionId

    $rows = @()
    if ($PSCmdlet.ShouldProcess('Resource Graph', 'Run query')) {
        Write-ToolkitLog -Message 'Running Resource Graph query' -Data @{
            source      = if ($QueryFile) { $QueryFile } else { 'inline' }
            queryLength = $queryText.Length
        }
        $rows = Get-GraphQueryResult -Query $queryText -OperationName 'Run Resource Graph query'
        Write-ToolkitLog -Message "$($rows.Count) row(s) returned"
    }

    $rows

    if ($ExportPath -and $rows.Count -gt 0) {
        $exportParams = @{ InputObject = $rows; Name = 'resource-graph-report'; OutputDirectory = $ExportPath }
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
