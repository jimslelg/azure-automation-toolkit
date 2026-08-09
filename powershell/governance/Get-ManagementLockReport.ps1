#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources

<#
.SYNOPSIS
    Reports management locks, or resource groups that should be locked but are not.
.DESCRIPTION
    Default mode lists every management lock in scope with its name, level
    (CanNotDelete/ReadOnly), the scope it protects, and its notes. With
    -FindUnprotected, the report inverts: it lists resource groups matching
    -UnprotectedTagFilter (format 'Key=Value', e.g. Environment=prod) that have no
    lock at resource-group or subscription scope. Read-only and exportable with
    -ExportPath.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER FindUnprotected
    Report tag-matched resource groups without a lock instead of listing locks.
.PARAMETER UnprotectedTagFilter
    Tag filter for -FindUnprotected in 'Key=Value' format (e.g. Environment=prod).
    Required when -FindUnprotected is set.
.PARAMETER ExportPath
    Optional directory to export results to (created if missing; timestamped filename).
.PARAMETER ExportFormat
    Export format when -ExportPath is supplied. Csv (default) or Json.
.EXAMPLE
    ./Get-ManagementLockReport.ps1

    Lists every management lock in the current subscription.
.EXAMPLE
    ./Get-ManagementLockReport.ps1 -FindUnprotected -UnprotectedTagFilter Environment=prod `
        -ExportPath ./output

    Reports production-tagged resource groups that carry no lock and exports the list.
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
    [switch]$FindUnprotected,

    [Parameter()]
    [ValidatePattern('^$|^[^=]+=[^=]+$')]
    [string]$UnprotectedTagFilter,

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

    if ($FindUnprotected -and -not $UnprotectedTagFilter) {
        $exception = [System.ArgumentException]::new('-FindUnprotected requires -UnprotectedTagFilter in Key=Value format.')
        throw [System.Management.Automation.ErrorRecord]::new(
            $exception, 'AzToolkit.ConfigurationInvalid.TagFilterMissing',
            [System.Management.Automation.ErrorCategory]::InvalidArgument, $null)
    }

    $null = Connect-ToolkitAzure -SubscriptionId $SubscriptionId

    $locks = @(Invoke-WithRetry -OperationName 'List management locks' -ScriptBlock {
            Get-AzResourceLock
        })
    Write-ToolkitLog -Message "$($locks.Count) management lock(s) in scope"

    if ($FindUnprotected) {
        $tagKey, $tagValue = $UnprotectedTagFilter -split '=', 2
        Write-ToolkitLog -Message "Finding resource groups tagged $tagKey=$tagValue without a lock"

        $resourceGroups = @(Invoke-WithRetry -OperationName 'List resource groups' -ScriptBlock {
                Get-AzResourceGroup
            } | Where-Object { $_.Tags -and $_.Tags[$tagKey] -eq $tagValue })

        $lockScopes = @($locks | ForEach-Object {
                ($_.ResourceId -split '/providers/Microsoft\.Authorization/locks/')[0]
            })

        $report = foreach ($resourceGroup in $resourceGroups) {
            $covered = [bool]($lockScopes | Where-Object {
                    $_ -eq $resourceGroup.ResourceId -or $resourceGroup.ResourceId -like "$_/*"
                })
            if (-not $covered) {
                [pscustomobject]@{
                    ResourceGroupName = $resourceGroup.ResourceGroupName
                    Location          = $resourceGroup.Location
                    TagFilter         = $UnprotectedTagFilter
                    Finding           = 'NoLock'
                }
            }
        }
        $report = @($report)
        Write-ToolkitLog -Message "$($report.Count) of $($resourceGroups.Count) tag-matched resource group(s) have no lock"
        $exportName = 'unprotected-resource-groups'
    }
    else {
        $report = @(foreach ($lock in $locks) {
                [pscustomobject]@{
                    Name  = $lock.Name
                    Level = [string]$lock.Properties.level
                    Scope = ($lock.ResourceId -split '/providers/Microsoft\.Authorization/locks/')[0]
                    Notes = [string]$lock.Properties.notes
                }
            })
        $exportName = 'management-locks'
    }

    $report

    if ($ExportPath -and $report.Count -gt 0) {
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
