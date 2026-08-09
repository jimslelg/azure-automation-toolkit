# Usage Walkthroughs

Real operational scenarios composed from the toolkit. All examples assume you are in
the repository root and authenticated (`Connect-AzAccount`).

## 1. Monthly cost-hygiene sweep

Find what's quietly burning money, review it, then clean it up with an audit trail:

```powershell
# 1. Survey: one Resource Graph sweep across every zombie class
./powershell/cleanup/Get-ZombieResources.ps1 -ExportPath ./output -ExportFormat Json

# 2. Deep-dive the two biggest offenders
./powershell/compute/Get-IdleVms.ps1 -CpuThresholdPercent 5 -LookbackDays 14
./powershell/storage/Get-OrphanedStorageAccounts.ps1 -LookbackDays 30

# 3. Preview the cleanup (nothing is deleted)
./powershell/cleanup/Remove-UnattachedDisks.ps1 -MinimumAgeDays 30 -WhatIf
./powershell/cleanup/Remove-UnusedSnapshots.ps1 -MinimumAgeDays 90 -WhatIf

# 4. Execute after review - disks tagged DoNotDelete are always skipped
./powershell/cleanup/Remove-UnattachedDisks.ps1 -MinimumAgeDays 30
```

## 2. Business-hours VM scheduling

Tag opt-in VMs once, then let the Automation runbooks handle the rhythm:

```powershell
# Opt a VM into scheduling
Update-AzTag -ResourceId $vm.Id -Tag @{ AutoSchedule = 'business-hours' } -Operation Merge

# Try the fleet operation interactively first
./powershell/compute/Stop-AzureVm.ps1 -TagName AutoSchedule -TagValue business-hours -WhatIf

# Then deploy the runbook pair on schedules (see automation-runbooks/README.md)
```

## 3. Certificate & secret expiry watch

```powershell
# Ad-hoc report across every vault you can read
./powershell/keyvault/Get-CertificateExpirationReport.ps1 -DaysUntilExpiry 45
./powershell/keyvault/Get-SecretExpirationReport.ps1 -ExportPath ./output

# Back up before rotating
./powershell/keyvault/Backup-KeyVaultSecrets.ps1 -VaultName kv-app-prod

# Rotate a secret with a generated value that expires in 90 days
./powershell/keyvault/Update-KeyVaultSecret.ps1 -VaultName kv-app-prod -Name api-key -GenerateRandom
```

## 4. Security posture snapshot

```powershell
./powershell/networking/Get-NsgAuditReport.ps1 -ExportPath ./output          # exposed ports
./powershell/sql/Get-SqlFirewallAuditReport.ps1                              # open SQL ranges
./powershell/governance/Get-RbacAuditReport.ps1                              # privileged access
./powershell/governance/Get-PolicyComplianceReport.ps1 -Detailed             # policy drift
```

Each emits severity-ranked objects, so composing a single report is one pipeline:

```powershell
$findings = & { ./powershell/networking/Get-NsgAuditReport.ps1; ./powershell/governance/Get-RbacAuditReport.ps1 }
$findings | Where-Object Severity -EQ 'High' | Format-Table
```

## 5. Onboarding a new subscription

```powershell
$sub = '00000000-0000-0000-0000-000000000000'

./powershell/reports/Export-AzureInventoryReport.ps1 -SubscriptionId $sub     # what exists
./powershell/reports/Get-SubscriptionHealthReport.ps1 -SubscriptionId $sub    # what's misconfigured
./powershell/governance/Get-ResourceTagAudit.ps1 -SubscriptionId $sub         # tagging debt
./powershell/reports/Export-MonthlyCostReport.ps1 -SubscriptionId $sub -GroupBy ServiceName
```

## 6. Wiring diagnostics to Log Analytics at scale

```powershell
$workspace = (Get-AzOperationalInsightsWorkspace -ResourceGroupName rg-ops -Name law-central).ResourceId
$keyVaults = Get-AzKeyVault | Select-Object -ExpandProperty ResourceId

./powershell/monitoring/Set-DiagnosticSettings.ps1 -TargetResourceId $keyVaults -WorkspaceResourceId $workspace -WhatIf
```

## Configuration file

Scripts with config-driven defaults (tag requirements, cleanup ages, thresholds) read
[`config/toolkit.settings.json`](config/toolkit.settings.json). Layer environments with
overlay files — `toolkit.settings.dev.json` wins over the base where keys overlap:

```powershell
$env:AZTOOLKIT_ENVIRONMENT = 'dev'   # picks up the dev overlay automatically
```

## CI / pipeline usage

In a pipeline, set three environment variables and every script authenticates as the
service principal with no code changes:

```yaml
env:
  AZURE_CLIENT_ID: $(clientId)
  AZURE_CLIENT_SECRET: $(clientSecret)
  AZURE_TENANT_ID: $(tenantId)
```

Exit codes make failures actionable: treat 3 (partial) as a warning gate, everything
else nonzero as a hard failure.
