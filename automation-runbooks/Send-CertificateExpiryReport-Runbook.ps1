<#
.SYNOPSIS
    Azure Automation runbook: reports Key Vault certificates and secrets nearing expiry.
.DESCRIPTION
    Scans every Key Vault visible to the Automation Account's managed identity and
    reports certificates and secrets that are expired or expire within
    -DaysUntilExpiry. The report is written to the job output and, when
    -TeamsWebhookUrl is supplied, posted to a Microsoft Teams incoming webhook so the
    on-call channel sees it. Read-only. Self-contained by design.
.PARAMETER DaysUntilExpiry
    Warning window in days. Default: 30.
.PARAMETER SubscriptionId
    Subscription to operate on. Defaults to the managed identity's default subscription.
.PARAMETER TeamsWebhookUrl
    Optional Microsoft Teams incoming-webhook URL to post the summary to.
.EXAMPLE
    Start-AzAutomationRunbook -AutomationAccountName aa-ops -ResourceGroupName rg-ops `
        -Name 'Send-CertificateExpiryReport-Runbook' -Parameters @{ DaysUntilExpiry = 45 }

    Runs the report with a 45-day warning window.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: managed identity with Key Vault Reader plus data-plane list/read
              (Key Vault Secrets User / Certificates Officer or access policies).
    Failure  : throws, marking the Automation job as Failed.
#>
param(
    [Parameter()]
    [int]$DaysUntilExpiry = 30,

    [Parameter()]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$TeamsWebhookUrl
)

$ErrorActionPreference = 'Stop'

# Authenticate as the Automation Account's system-assigned managed identity.
$null = Disable-AzContextAutosave -Scope Process
$null = Connect-AzAccount -Identity
if ($SubscriptionId) {
    $null = Set-AzContext -SubscriptionId $SubscriptionId
}

$deadline = (Get-Date).AddDays($DaysUntilExpiry)
$findings = [System.Collections.Generic.List[pscustomobject]]::new()
$vaults = @(Get-AzKeyVault)
Write-Output "Scanning $($vaults.Count) Key Vault(s) for items expiring before $($deadline.ToString('yyyy-MM-dd'))"

$failed = 0
foreach ($vault in $vaults) {
    try {
        foreach ($certificate in @(Get-AzKeyVaultCertificate -VaultName $vault.VaultName)) {
            if ($certificate.Expires -and $certificate.Expires -le $deadline) {
                $findings.Add([pscustomobject]@{
                        Vault    = $vault.VaultName
                        Type     = 'Certificate'
                        Name     = $certificate.Name
                        Expires  = $certificate.Expires.ToString('yyyy-MM-dd')
                        DaysLeft = [int]($certificate.Expires - (Get-Date)).TotalDays
                    })
            }
        }
        foreach ($secret in @(Get-AzKeyVaultSecret -VaultName $vault.VaultName)) {
            if ($secret.Expires -and $secret.Expires -le $deadline) {
                $findings.Add([pscustomobject]@{
                        Vault    = $vault.VaultName
                        Type     = 'Secret'
                        Name     = $secret.Name
                        Expires  = $secret.Expires.ToString('yyyy-MM-dd')
                        DaysLeft = [int]($secret.Expires - (Get-Date)).TotalDays
                    })
            }
        }
    }
    catch {
        $failed++
        Write-Warning "Could not scan vault '$($vault.VaultName)': $($_.Exception.Message)"
    }
}

if ($findings.Count -eq 0) {
    Write-Output "No certificates or secrets expire within $DaysUntilExpiry day(s)."
}
else {
    Write-Output "$($findings.Count) item(s) expired or expiring within $DaysUntilExpiry day(s):"
    foreach ($finding in $findings | Sort-Object DaysLeft) {
        Write-Output ("{0,-12} {1,-30} vault={2,-24} expires={3} ({4} days)" -f `
                $finding.Type, $finding.Name, $finding.Vault, $finding.Expires, $finding.DaysLeft)
    }
}

if ($TeamsWebhookUrl -and $findings.Count -gt 0) {
    $lines = $findings | Sort-Object DaysLeft | ForEach-Object {
        "- **$($_.Name)** ($($_.Type), vault ``$($_.Vault)``) expires $($_.Expires) ($($_.DaysLeft) days)"
    }
    $payload = @{
        title = "Key Vault expiry report: $($findings.Count) item(s) within $DaysUntilExpiry days"
        text  = $lines -join "`n"
    } | ConvertTo-Json -Depth 3
    $null = Invoke-RestMethod -Method Post -Uri $TeamsWebhookUrl -ContentType 'application/json' -Body $payload
    Write-Output 'Summary posted to Teams webhook'
}

if ($failed -gt 0) {
    throw "$failed vault(s) could not be scanned; see warnings above."
}
Write-Output 'Completed successfully'
