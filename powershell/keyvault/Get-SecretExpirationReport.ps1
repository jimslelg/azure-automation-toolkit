#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.KeyVault

<#
.SYNOPSIS
    Reports Key Vault secrets that are expired, expiring soon, or missing an expiry date.
.DESCRIPTION
    Scans every Key Vault in scope (or a single vault with -VaultName) and evaluates the
    expiry metadata of each secret. Read-only: only secret names, versions, and dates are
    read - secret values are never retrieved or logged. Emits one object per finding with
    a status of Expired, ExpiringSoon, NoExpirySet, or Ok; healthy secrets are omitted
    unless -IncludeHealthy is set. Results can be exported with -ExportPath.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER VaultName
    Optional single Key Vault to scan; every vault in the subscription otherwise.
.PARAMETER DaysUntilExpiry
    Window in days within which a secret counts as ExpiringSoon (default 30).
.PARAMETER IncludeHealthy
    Also emit secrets with status Ok instead of only the problematic ones.
.PARAMETER ExportPath
    Optional directory to export results to (created if missing; timestamped filename).
.PARAMETER ExportFormat
    Export format when -ExportPath is supplied. Csv (default) or Json.
.EXAMPLE
    ./Get-SecretExpirationReport.ps1 -DaysUntilExpiry 45

    Reports expired, soon-to-expire, and expiry-less secrets across every vault in scope.
.EXAMPLE
    ./Get-SecretExpirationReport.ps1 -VaultName kv-app-prod -IncludeHealthy -ExportPath ./output

    Full secret expiry inventory for one vault, exported as CSV.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Key Vault Secrets User (or list permission via access policy) on each vault.
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure
                (some vaults could not be read), 4 invalid parameters/configuration.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$VaultName,

    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$DaysUntilExpiry = 30,

    [Parameter()]
    [switch]$IncludeHealthy,

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

    $vaults = if ($VaultName) {
        @(Invoke-WithRetry -OperationName "Get vault $VaultName" -ScriptBlock { Get-AzKeyVault -VaultName $VaultName })
    }
    else {
        @(Invoke-WithRetry -OperationName 'List vaults' -ScriptBlock { Get-AzKeyVault })
    }

    if ($vaults.Count -eq 0) {
        Write-ToolkitLog -Level Warning -Message 'No Key Vaults matched the selection criteria'
    }
    Write-ToolkitLog -Message "Scanning $($vaults.Count) vault(s) with an expiry window of $DaysUntilExpiry day(s)"

    $now = [datetime]::UtcNow
    $failures = 0
    $report = foreach ($vault in $vaults) {
        try {
            $secrets = @(Invoke-WithRetry -OperationName "List secrets in $($vault.VaultName)" -ScriptBlock {
                    Get-AzKeyVaultSecret -VaultName $vault.VaultName
                })
            Write-ToolkitLog -Message 'Vault scanned' -Data @{
                vault       = $vault.VaultName
                secretCount = $secrets.Count
            }

            foreach ($secret in $secrets) {
                $daysLeft = $null
                if ($null -eq $secret.Expires) {
                    $status = 'NoExpirySet'
                }
                else {
                    $daysLeft = [int][Math]::Floor(($secret.Expires.ToUniversalTime() - $now).TotalDays)
                    $status = if ($daysLeft -lt 0) { 'Expired' }
                    elseif ($daysLeft -le $DaysUntilExpiry) { 'ExpiringSoon' }
                    else { 'Ok' }
                }

                if ($status -eq 'Ok' -and -not $IncludeHealthy) {
                    continue
                }

                [pscustomobject]@{
                    VaultName       = $vault.VaultName
                    Name            = $secret.Name
                    Enabled         = $secret.Enabled
                    Created         = $secret.Created
                    Expires         = $secret.Expires
                    DaysUntilExpiry = $daysLeft
                    Status          = $status
                }
            }
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Failed to scan vault '$($vault.VaultName)'" -ErrorRecord $_
        }
    }

    $report = @($report)
    if ($failures -gt 0 -and $failures -lt $vaults.Count) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $vaults.Count -gt 0) { throw "Secret scan failed for all $failures vault(s)." }

    Write-ToolkitLog -Message "$($report.Count) secret finding(s) reported"
    $report

    if ($ExportPath -and $report.Count -gt 0) {
        $exportParams = @{ InputObject = $report; Name = 'secret-expiration-report'; OutputDirectory = $ExportPath }
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
