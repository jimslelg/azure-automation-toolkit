#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.KeyVault

<#
.SYNOPSIS
    Backs up every enabled secret of a Key Vault to encrypted backup blobs on disk.
.DESCRIPTION
    Downloads a backup blob for each enabled secret in the given vault using
    Backup-AzKeyVaultSecret. Each secret is processed with its own error isolation, so
    one failed secret does not abort the run (partial failure exits 3). Secret values
    are never decrypted, displayed, or logged - only names and file paths. Emits one
    result object per secret with the backup file path and status.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER VaultName
    Name of the Key Vault whose enabled secrets are backed up.
.PARAMETER BackupDirectory
    Directory to write the backup blobs to (created if missing). Defaults to
    ./backups/<vault>_<yyyyMMdd_HHmmss>/.
.EXAMPLE
    ./Backup-KeyVaultSecrets.ps1 -VaultName kv-app-prod

    Backs up every enabled secret of kv-app-prod into a timestamped ./backups/ folder.
.EXAMPLE
    ./Backup-KeyVaultSecrets.ps1 -VaultName kv-app-prod -BackupDirectory /mnt/kv-backups/prod

    Backs up secrets into an explicit directory, e.g. a mounted backup share.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Key Vault Secrets Officer (or backup permission via access policy).
    The backup blobs are encrypted by Azure Key Vault and cannot be read offline; they
    can only be restored (Restore-KeyVaultSecrets.ps1) into a Key Vault that lives in
    the same Azure geography as the source vault.
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure
                (some secrets failed to back up), 4 invalid parameters/configuration.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$VaultName,

    [Parameter()]
    [string]$BackupDirectory
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'AzToolkit.Common.psd1') -Force

$exitCode = 0
try {
    $null = Initialize-ToolkitLog -ScriptName $MyInvocation.MyCommand.Name
    $null = Connect-ToolkitAzure -SubscriptionId $SubscriptionId

    if (-not $BackupDirectory) {
        $BackupDirectory = Join-Path '.' 'backups' ('{0}_{1}' -f $VaultName, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    }
    if (-not (Test-Path -LiteralPath $BackupDirectory)) {
        $null = New-Item -Path $BackupDirectory -ItemType Directory -Force
    }
    $BackupDirectory = (Resolve-Path -LiteralPath $BackupDirectory).Path
    Write-ToolkitLog -Message 'Backup target prepared' -Data @{
        vault           = $VaultName
        backupDirectory = $BackupDirectory
    }

    $secrets = @(Invoke-WithRetry -OperationName "List secrets in $VaultName" -ScriptBlock {
            Get-AzKeyVaultSecret -VaultName $VaultName
        } | Where-Object Enabled)

    if ($secrets.Count -eq 0) {
        Write-ToolkitLog -Level Warning -Message "No enabled secrets found in vault '$VaultName'"
    }
    Write-ToolkitLog -Message "Backing up $($secrets.Count) enabled secret(s) from '$VaultName'"

    $failures = 0
    $results = foreach ($secret in $secrets) {
        $outputFile = Join-Path $BackupDirectory "$($secret.Name).kvbackup"
        try {
            $null = Invoke-WithRetry -OperationName "Backup secret $($secret.Name)" -ScriptBlock {
                Backup-AzKeyVaultSecret -VaultName $VaultName -Name $secret.Name -OutputFile $outputFile -Force
            }
            Write-ToolkitLog -Message 'Secret backed up' -Data @{
                secret = $secret.Name
                file   = $outputFile
            }
            [pscustomobject]@{
                SecretName = $secret.Name
                BackupFile = $outputFile
                Status     = 'BackedUp'
            }
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Failed to back up secret '$($secret.Name)'" -ErrorRecord $_
            [pscustomobject]@{
                SecretName = $secret.Name
                BackupFile = $null
                Status     = 'Failed'
            }
        }
    }

    if ($failures -gt 0 -and $failures -lt $secrets.Count) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $secrets.Count -gt 0) { throw "All $failures secret backup(s) failed." }

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
