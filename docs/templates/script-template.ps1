#Requires -Version 7.0
#Requires -Modules Az.Accounts

<#
.SYNOPSIS
    One-line statement of what the script does.
.DESCRIPTION
    Two to five sentences: what the script queries or changes, what it emits to the
    pipeline, whether it is read-only, and any prerequisites (roles, modules).
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context when omitted.
.PARAMETER ExportPath
    Optional directory to export results to (created if missing; timestamped filename).
.PARAMETER ExportFormat
    Export format when -ExportPath is supplied. Csv (default) or Json.
.EXAMPLE
    ./Verb-Noun.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000

    Runs against the given subscription and emits result objects to the pipeline.
.EXAMPLE
    ./Verb-Noun.ps1 -ExportPath ./output -ExportFormat Json -WhatIf

    Previews changes without applying them and shows where results would be exported.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure,
                4 invalid parameters/configuration, 5 no matching resources.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

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

    # --- main logic -----------------------------------------------------------
    # Collect work items first, then process with per-item error isolation.
    $results = [System.Collections.Generic.List[pscustomobject]]::new()
    $failures = 0
    $items = @() # e.g. Invoke-WithRetry -OperationName 'List VMs' -ScriptBlock { Get-AzVM }

    foreach ($item in $items) {
        try {
            if ($PSCmdlet.ShouldProcess($item.Name, 'Describe the action')) {
                # Perform the change / collect the data, wrapping Azure calls:
                # Invoke-WithRetry -OperationName "Action $($item.Name)" -ScriptBlock { ... }
                $results.Add([pscustomobject]@{ Name = $item.Name })
            }
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Failed processing '$($item.Name)'" -ErrorRecord $_
        }
    }

    if ($failures -gt 0 -and $failures -lt $items.Count) { $exitCode = 3 }
    elseif ($failures -gt 0) { throw "All $failures item(s) failed processing." }
    # --------------------------------------------------------------------------

    $results

    if ($ExportPath -and $results.Count -gt 0) {
        $exportParams = @{ InputObject = $results; Name = 'verb-noun'; OutputDirectory = $ExportPath }
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
