#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.KeyVault

<#
.SYNOPSIS
    Rotates a single Key Vault secret by writing a new version with a fresh expiry date.
.DESCRIPTION
    Creates a new version of one secret, either from a caller-supplied [securestring]
    (-NewValue) or from a cryptographically random alphanumeric+symbol value
    (-GenerateRandom). The new version gets an expiry of now plus -ValidityDays and a
    rotatedBy=azure-automation-toolkit tag. Gated by ShouldProcess (-WhatIf/-Confirm).
    The secret value is never written to the pipeline, console, or log - the result
    object carries only the name, new version, and expiry date.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER VaultName
    Name of the Key Vault containing the secret.
.PARAMETER Name
    Name of the secret to rotate.
.PARAMETER NewValue
    New secret value as a [securestring]. Mutually exclusive with -GenerateRandom;
    exactly one of the two must be supplied.
.PARAMETER GenerateRandom
    Generate a cryptographically random value instead of supplying one. Mutually
    exclusive with -NewValue; exactly one of the two must be supplied.
.PARAMETER RandomLength
    Length of the generated value when -GenerateRandom is used (default 32).
.PARAMETER ValidityDays
    Days until the new secret version expires (default 90).
.EXAMPLE
    ./Update-KeyVaultSecret.ps1 -VaultName kv-app-prod -Name sql-connection -GenerateRandom -WhatIf

    Shows the rotation that would happen without writing a new version.
.EXAMPLE
    ./Update-KeyVaultSecret.ps1 -VaultName kv-app-prod -Name api-key -NewValue (Read-Host -AsSecureString) -ValidityDays 30

    Rotates api-key to an interactively entered value that expires in 30 days.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Key Vault Secrets Officer (or set permission via access policy).
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure,
                4 invalid parameters/configuration (neither or both of -NewValue and
                -GenerateRandom supplied).
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
    [string]$Name,

    [Parameter()]
    [securestring]$NewValue,

    [Parameter()]
    [switch]$GenerateRandom,

    [Parameter()]
    [ValidateRange(8, 128)]
    [int]$RandomLength = 32,

    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$ValidityDays = 90
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'AzToolkit.Common.psd1') -Force

$exitCode = 0
try {
    $null = Initialize-ToolkitLog -ScriptName $MyInvocation.MyCommand.Name

    if ($PSBoundParameters.ContainsKey('NewValue') -eq [bool]$GenerateRandom) {
        $exception = [System.ArgumentException]::new('Supply exactly one of -NewValue or -GenerateRandom.')
        throw [System.Management.Automation.ErrorRecord]::new(
            $exception, 'AzToolkit.ConfigurationInvalid', [System.Management.Automation.ErrorCategory]::InvalidArgument, $null)
    }

    $null = Connect-ToolkitAzure -SubscriptionId $SubscriptionId

    $secretValue = if ($GenerateRandom) {
        # Build the value directly inside a SecureString so no plaintext copy ever
        # exists in a managed string; indices come from the CSPRNG (no modulo bias).
        $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()-_=+'
        $generated = [securestring]::new()
        for ($i = 0; $i -lt $RandomLength; $i++) {
            $index = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($alphabet.Length)
            $generated.AppendChar($alphabet[$index])
        }
        $generated
    }
    else {
        $NewValue
    }

    $expires = [datetime]::UtcNow.AddDays($ValidityDays)
    $results = @()
    if ($PSCmdlet.ShouldProcess("$VaultName/$Name", "Set new secret version (expires $($expires.ToString('yyyy-MM-dd')))")) {
        $newSecret = Invoke-WithRetry -OperationName "Set secret $Name" -ScriptBlock {
            Set-AzKeyVaultSecret -VaultName $VaultName -Name $Name -SecretValue $secretValue `
                -Expires $expires -Tag @{ rotatedBy = 'azure-automation-toolkit' }
        }
        Write-ToolkitLog -Message 'Secret rotated' -Data @{
            vault      = $VaultName
            secret     = $Name
            newVersion = $newSecret.Version
            expires    = $expires.ToString('o')
        }
        $results = @([pscustomobject]@{
                Name       = $newSecret.Name
                NewVersion = $newSecret.Version
                Expires    = $expires
            })
    }

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
