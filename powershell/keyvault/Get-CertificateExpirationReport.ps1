#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.KeyVault

<#
.SYNOPSIS
    Reports Key Vault certificates that are expired, expiring soon, or missing an expiry date.
.DESCRIPTION
    Scans every Key Vault in scope (or a single vault with -VaultName) and evaluates the
    expiry of each certificate, including its thumbprint and subject. Read-only: only
    certificate metadata is read - private keys and secret material are never retrieved.
    Emits one object per finding with a status of Expired, ExpiringSoon, NoExpirySet, or
    Ok; healthy certificates are omitted unless -IncludeHealthy is set. Results can be
    exported with -ExportPath.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER VaultName
    Optional single Key Vault to scan; every vault in the subscription otherwise.
.PARAMETER DaysUntilExpiry
    Window in days within which a certificate counts as ExpiringSoon (default 30).
.PARAMETER IncludeHealthy
    Also emit certificates with status Ok instead of only the problematic ones.
.PARAMETER ExportPath
    Optional directory to export results to (created if missing; timestamped filename).
.PARAMETER ExportFormat
    Export format when -ExportPath is supplied. Csv (default) or Json.
.EXAMPLE
    ./Get-CertificateExpirationReport.ps1 -DaysUntilExpiry 60

    Reports certificates expiring within 60 days across every vault in scope.
.EXAMPLE
    ./Get-CertificateExpirationReport.ps1 -VaultName kv-app-prod -IncludeHealthy -ExportPath ./output -ExportFormat Json

    Full certificate expiry inventory for one vault, exported as JSON.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Key Vault Certificates Officer/User (or list+get via access policy) on each vault.
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure
                (some vaults or certificates could not be read), 4 invalid parameters/configuration.
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
    $itemCount = 0
    $report = foreach ($vault in $vaults) {
        try {
            $certificates = @(Invoke-WithRetry -OperationName "List certificates in $($vault.VaultName)" -ScriptBlock {
                    Get-AzKeyVaultCertificate -VaultName $vault.VaultName
                })
            Write-ToolkitLog -Message 'Vault scanned' -Data @{
                vault            = $vault.VaultName
                certificateCount = $certificates.Count
            }

            foreach ($certificate in $certificates) {
                $itemCount++
                try {
                    $detail = Invoke-WithRetry -OperationName "Get certificate $($certificate.Name)" -ScriptBlock {
                        Get-AzKeyVaultCertificate -VaultName $vault.VaultName -Name $certificate.Name
                    }

                    $daysLeft = $null
                    if ($null -eq $detail.Expires) {
                        $status = 'NoExpirySet'
                    }
                    else {
                        $daysLeft = [int][Math]::Floor(($detail.Expires.ToUniversalTime() - $now).TotalDays)
                        $status = if ($daysLeft -lt 0) { 'Expired' }
                        elseif ($daysLeft -le $DaysUntilExpiry) { 'ExpiringSoon' }
                        else { 'Ok' }
                    }

                    if ($status -eq 'Ok' -and -not $IncludeHealthy) {
                        continue
                    }

                    [pscustomobject]@{
                        VaultName       = $vault.VaultName
                        Name            = $detail.Name
                        Enabled         = $detail.Enabled
                        Thumbprint      = $detail.Certificate.Thumbprint
                        Subject         = $detail.Certificate.Subject
                        Created         = $detail.Created
                        Expires         = $detail.Expires
                        DaysUntilExpiry = $daysLeft
                        Status          = $status
                    }
                }
                catch {
                    $failures++
                    Write-ToolkitLog -Level Error -Message "Failed to read certificate '$($certificate.Name)' in vault '$($vault.VaultName)'" -ErrorRecord $_
                }
            }
        }
        catch {
            $failures++
            $itemCount++
            Write-ToolkitLog -Level Error -Message "Failed to scan vault '$($vault.VaultName)'" -ErrorRecord $_
        }
    }

    $report = @($report)
    if ($failures -gt 0 -and $failures -lt $itemCount) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $itemCount -gt 0) { throw "Certificate scan failed for all $failures item(s)." }

    Write-ToolkitLog -Message "$($report.Count) certificate finding(s) reported"
    $report

    if ($ExportPath -and $report.Count -gt 0) {
        $exportParams = @{ InputObject = $report; Name = 'certificate-expiration-report'; OutputDirectory = $ExportPath }
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
