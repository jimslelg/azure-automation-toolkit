#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Storage

<#
.SYNOPSIS
    Removes storage tables matching a wildcard name pattern from a storage account.
.DESCRIPTION
    Lists the tables in the given storage account and removes every table whose name
    matches -NamePattern (PowerShell wildcard). As a guard against wiping an account,
    a plain '*' pattern is rejected unless -Force is also passed. Each table removal
    is gated through ShouldProcess, so -WhatIf previews the operation. Emits one
    result object per matched table with the outcome.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ResourceGroupName
    Resource group containing the storage account.
.PARAMETER StorageAccountName
    Storage account whose tables are removed.
.PARAMETER NamePattern
    Wildcard pattern matched against table names (e.g. 'WADMetrics*'). A plain '*'
    requires -Force.
.PARAMETER Force
    Required alongside -NamePattern '*' to confirm removing every table in the account.
.EXAMPLE
    ./Clear-StorageTables.ps1 -ResourceGroupName rg-data -StorageAccountName stdata01 -NamePattern 'WADMetrics*' -WhatIf

    Previews which diagnostics tables would be removed.
.EXAMPLE
    ./Clear-StorageTables.ps1 -ResourceGroupName rg-data -StorageAccountName stdata01 -NamePattern '*' -Force

    Removes every table in the account (explicitly confirmed with -Force).
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Storage Table Data Contributor (or account key access) on the target account.
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure,
                4 invalid parameters/configuration (plain '*' without -Force).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$StorageAccountName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$NamePattern,

    [Parameter()]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'AzToolkit.Common.psd1') -Force

$exitCode = 0
try {
    $null = Initialize-ToolkitLog -ScriptName $MyInvocation.MyCommand.Name

    if ($NamePattern -eq '*' -and -not $Force) {
        $message = "NamePattern '*' would remove every table in '$StorageAccountName'; pass -Force to confirm this intent."
        $exception = [System.ArgumentException]::new($message)
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            $exception,
            'AzToolkit.ConfigurationInvalid',
            [System.Management.Automation.ErrorCategory]::InvalidArgument,
            $NamePattern)
        throw $errorRecord
    }

    $null = Connect-ToolkitAzure -SubscriptionId $SubscriptionId

    $account = Invoke-WithRetry -OperationName "Get storage account $StorageAccountName" -ScriptBlock {
        Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
    }

    $matchedTables = @(Invoke-WithRetry -OperationName "List tables in $StorageAccountName" -ScriptBlock {
            Get-AzStorageTable -Context $account.Context
        } | Where-Object Name -Like $NamePattern)

    Write-ToolkitLog -Message "$($matchedTables.Count) table(s) match pattern '$NamePattern' in '$StorageAccountName'"
    if ($matchedTables.Count -eq 0) {
        Write-ToolkitLog -Level Warning -Message 'No tables matched the pattern; nothing to remove'
    }

    $failures = 0
    $results = foreach ($table in $matchedTables) {
        if (-not $PSCmdlet.ShouldProcess("$StorageAccountName/$($table.Name)", 'Remove storage table')) {
            continue
        }
        try {
            Write-ToolkitLog -Message 'Removing storage table' -Data @{
                account = $StorageAccountName
                table   = $table.Name
            }
            Invoke-WithRetry -OperationName "Remove table $($table.Name)" -ScriptBlock {
                Remove-AzStorageTable -Name $table.Name -Context $account.Context -Force
            }
            [pscustomobject]@{
                StorageAccountName = $StorageAccountName
                ResourceGroupName  = $ResourceGroupName
                TableName          = $table.Name
                Status             = 'Removed'
            }
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Failed to remove table '$($table.Name)'" -ErrorRecord $_
            [pscustomobject]@{
                StorageAccountName = $StorageAccountName
                ResourceGroupName  = $ResourceGroupName
                TableName          = $table.Name
                Status             = 'Failed'
            }
        }
    }

    if ($failures -gt 0 -and $failures -lt $matchedTables.Count) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $matchedTables.Count -gt 0) { throw "All $failures table removal(s) failed." }

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
