#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.KeyVault

<#
.SYNOPSIS
    Restores Key Vault secret backup blobs from a directory into a target vault.
.DESCRIPTION
    Restores every *.kvbackup and *.blob file found in -BackupDirectory into the given
    Key Vault using Restore-AzKeyVaultSecret. Each file is gated by ShouldProcess
    (-WhatIf/-Confirm supported) and processed with its own error isolation. A secret
    that already exists in the target vault cannot be overwritten by a restore - those
    files are reported with status AlreadyExists and skipped. Secret values are never
    displayed or logged. Partial failure exits 3.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER VaultName
    Name of the Key Vault to restore the secrets into. Must live in the same Azure
    geography as the vault the backups were taken from.
.PARAMETER BackupDirectory
    Directory containing the backup blobs (*.kvbackup or *.blob). Must exist.
.EXAMPLE
    ./Restore-KeyVaultSecrets.ps1 -VaultName kv-app-dr -BackupDirectory ./backups/kv-app-prod_20260810_120000 -WhatIf

    Shows which backup files would be restored without touching the vault.
.EXAMPLE
    ./Restore-KeyVaultSecrets.ps1 -VaultName kv-app-dr -BackupDirectory ./backups/kv-app-prod_20260810_120000

    Restores every backup blob in the directory into kv-app-dr.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Key Vault Secrets Officer (or restore permission via access policy).
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure
                (some files failed to restore), 4 invalid parameters/configuration.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$VaultName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$BackupDirectory
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'AzToolkit.Common.psd1') -Force

$exitCode = 0
try {
    $null = Initialize-ToolkitLog -ScriptName $MyInvocation.MyCommand.Name

    if (-not (Test-Path -LiteralPath $BackupDirectory -PathType Container)) {
        $exception = [System.ArgumentException]::new("Backup directory '$BackupDirectory' does not exist.")
        throw [System.Management.Automation.ErrorRecord]::new(
            $exception, 'AzToolkit.ConfigurationInvalid', [System.Management.Automation.ErrorCategory]::InvalidArgument, $BackupDirectory)
    }

    $null = Connect-ToolkitAzure -SubscriptionId $SubscriptionId

    $backupFiles = @(Get-ChildItem -LiteralPath $BackupDirectory -File |
            Where-Object { $_.Extension -in '.kvbackup', '.blob' })

    if ($backupFiles.Count -eq 0) {
        Write-ToolkitLog -Level Warning -Message "No *.kvbackup or *.blob files found in '$BackupDirectory'"
    }
    Write-ToolkitLog -Message "Restoring $($backupFiles.Count) backup file(s) into vault '$VaultName'"

    $failures = 0
    $results = foreach ($file in $backupFiles) {
        if (-not $PSCmdlet.ShouldProcess($file.Name, "Restore secret into vault '$VaultName'")) {
            continue
        }
        try {
            $restored = Invoke-WithRetry -OperationName "Restore $($file.Name)" -ScriptBlock {
                Restore-AzKeyVaultSecret -VaultName $VaultName -InputFile $file.FullName
            }
            Write-ToolkitLog -Message 'Secret restored' -Data @{
                secret = $restored.Name
                file   = $file.FullName
            }
            [pscustomobject]@{
                SecretName = $restored.Name
                BackupFile = $file.FullName
                Status     = 'Restored'
            }
        }
        catch {
            if ($_.Exception.Message -match 'already exists|Conflict') {
                Write-ToolkitLog -Level Warning -Message "Secret from '$($file.Name)' already exists in '$VaultName' - skipping"
                [pscustomobject]@{
                    SecretName = $file.BaseName
                    BackupFile = $file.FullName
                    Status     = 'AlreadyExists'
                }
            }
            else {
                $failures++
                Write-ToolkitLog -Level Error -Message "Failed to restore '$($file.Name)'" -ErrorRecord $_
                [pscustomobject]@{
                    SecretName = $file.BaseName
                    BackupFile = $file.FullName
                    Status     = 'Failed'
                }
            }
        }
    }

    if ($failures -gt 0 -and $failures -lt $backupFiles.Count) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $backupFiles.Count -gt 0) { throw "All $failures secret restore(s) failed." }

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
