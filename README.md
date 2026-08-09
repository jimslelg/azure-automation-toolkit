# Azure Automation Toolkit

[![CI](https://github.com/jimslelg/azure-automation-toolkit/actions/workflows/ci.yml/badge.svg)](https://github.com/jimslelg/azure-automation-toolkit/actions/workflows/ci.yml)
[![PowerShell 7](https://img.shields.io/badge/PowerShell-7.0%2B-blue)](https://learn.microsoft.com/en-us/powershell/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

An enterprise-grade collection of **43 production-ready PowerShell scripts**, Azure
Automation runbooks, and Azure CLI tools for day-to-day cloud operations: VM lifecycle,
storage hygiene, network audits, Key Vault expiry management, SQL health, monitoring
setup, governance reporting, zombie-resource cleanup, and subscription-wide inventory
and cost reporting.

Built the way an operations team would actually run it:

- **One shared module** (`AzToolkit.Common`) provides authentication (Managed Identity /
  service principal / interactive auto-detection), structured JSON-lines logging with
  correlation IDs, exponential-backoff retry with transient-error classification,
  layered JSON configuration, and timestamped CSV/JSON exporters.
- **Every script** ships comment-based help, parameter validation, `-WhatIf` support on
  anything destructive, per-item error isolation, meaningful exit codes, and log-file
  output — enforced mechanically by an AST-based conformance test suite, not by review
  discipline.
- **CI on both platforms**: GitHub Actions and a multi-stage Azure DevOps pipeline
  (lint → test → package the module for Azure Automation).

## Repository layout

```
azure-automation-toolkit/
├── powershell/            43 operational scripts in 9 categories
│   ├── compute/           VM start/stop/restart/resize, idle detection, inventory
│   ├── storage/           boot-diag & blob cleanup, orphaned accounts, usage
│   ├── networking/        NSG audit, unused NICs/LBs/PIPs, network inventory
│   ├── keyvault/          secret/cert expiry, backup, restore, rotation
│   ├── sql/               inventory, backup verification, firewall audit, pools
│   ├── monitoring/        alert rules, diagnostic settings, metrics, KQL
│   ├── governance/        tag/RBAC/policy/lock audits
│   ├── cleanup/           unattached disks, snapshots, zombie resources
│   └── reports/           Resource Graph inventory, cost, subscription health
├── automation-runbooks/   Managed-Identity runbooks for Azure Automation
├── azure-cli/             bash + JMESPath counterparts for flagship scenarios
├── shared/                AzToolkit.Common PowerShell module
├── tests/                 Pester unit + conformance suites (run offline)
├── docs/                  coding standards, templates, roadmap
├── examples/              configuration samples and usage walkthroughs
└── .github/workflows/     CI
```

## Quick start

```powershell
git clone https://github.com/jimslelg/azure-automation-toolkit.git
cd azure-automation-toolkit

# Prerequisites (PowerShell 7+)
Install-Module Az -Scope CurrentUser

# Authenticate once - scripts auto-detect context, managed identity, or SPN env vars
Connect-AzAccount

# Read-only examples
./powershell/compute/Get-IdleVms.ps1 -CpuThresholdPercent 5 -LookbackDays 14
./powershell/networking/Get-NsgAuditReport.ps1 -ExportPath ./output

# Destructive scripts always support preview
./powershell/cleanup/Remove-UnattachedDisks.ps1 -MinimumAgeDays 30 -WhatIf
```

Every script emits objects to the pipeline (filter/sort/pipe as usual), writes a
JSON-lines log to `./logs/`, and exports reports with `-ExportPath`/`-ExportFormat`.

## Authentication

`Connect-ToolkitAzure` picks the right method automatically, in this order:

| Priority | Method | Trigger |
|---|---|---|
| 1 | Explicit override | `AZTOOLKIT_AUTH_MODE` env var |
| 2 | Managed Identity | `IDENTITY_ENDPOINT`/`MSI_ENDPOINT` present (VM, App Service, Automation) |
| 3 | Service Principal | `AZURE_CLIENT_ID` + `AZURE_CLIENT_SECRET` + `AZURE_TENANT_ID` (CI/CD) |
| 4 | Existing context | A valid `Get-AzContext` session |
| 5 | Interactive | Browser login fallback |

Authentication failures map to **exit code 2**; the full exit-code contract
(0 ok, 1 failure, 2 auth, 3 partial, 4 bad input/config, 5 nothing matched) is defined
in [docs/coding-standards.md](docs/coding-standards.md).

## Script catalog

### compute
| Script | Purpose |
|---|---|
| `Start-AzureVm.ps1` | Start VMs by name or tag (fleet-safe, per-VM isolation) |
| `Stop-AzureVm.ps1` | Deallocate (default) or power off VMs by name or tag |
| `Restart-AzureVm.ps1` | Rolling restarts with configurable delay |
| `Set-VmSize.ps1` | Resize with cluster-availability validation |
| `Get-IdleVms.ps1` | Right-sizing candidates via Azure Monitor CPU metrics |
| `Export-VmInventory.ps1` | Full VM inventory (state, size, OS, disks, tags) |

### storage
| Script | Purpose |
|---|---|
| `Remove-OldBootDiagnostics.ps1` | Purge aged `bootdiagnostics-*` blobs |
| `Remove-UnusedBlobs.ps1` | Delete stale blobs with an explicit safety cap |
| `Get-OrphanedStorageAccounts.ps1` | Zero-transaction accounts over a lookback window |
| `Get-StorageAccountUsage.ps1` | Capacity, tier, TLS, and network-access posture |
| `Clear-StorageTables.ps1` | Pattern-guarded storage table removal |

### networking
| Script | Purpose |
|---|---|
| `Get-PublicIpAddresses.ps1` | All PIPs with association state and SKU |
| `Get-UnusedNics.ps1` | NICs attached to nothing |
| `Get-UnattachedLoadBalancers.ps1` | LBs with empty backend pools |
| `Get-NsgAuditReport.ps1` | Internet-open rules on sensitive ports, by severity |
| `Export-NetworkInventory.ps1` | VNets, subnets, peerings + per-RG counts |

### keyvault
| Script | Purpose |
|---|---|
| `Get-SecretExpirationReport.ps1` | Expired / expiring / no-expiry secrets |
| `Get-CertificateExpirationReport.ps1` | Same for certificates, with thumbprints |
| `Backup-KeyVaultSecrets.ps1` | Bulk secret backup to encrypted blobs |
| `Restore-KeyVaultSecrets.ps1` | Bulk restore with already-exists handling |
| `Update-KeyVaultSecret.ps1` | Rotation sample - CSPRNG value, new expiry, never leaks the value |

### sql
| Script | Purpose |
|---|---|
| `Get-SqlInventory.ps1` | Servers, databases, SKUs, pools |
| `Test-SqlBackupStatus.ps1` | PITR window + LTR policy verification |
| `Get-SqlFirewallAuditReport.ps1` | Open ranges and Azure-services access, by severity |
| `Get-ElasticPoolReport.ps1` | Pool utilization and database distribution |

### monitoring
| Script | Purpose |
|---|---|
| `New-AzureMonitorAlert.ps1` | Metric alert rules with action group wiring |
| `Set-DiagnosticSettings.ps1` | Bulk diagnostic settings → Log Analytics |
| `Export-AzureMetrics.ps1` | Metric time series to CSV/JSON |
| `Invoke-LogAnalyticsQuery.ps1` | KQL runner (inline or .kql file) |

### governance
| Script | Purpose |
|---|---|
| `Get-ResourceTagAudit.ps1` | Per-resource required-tag compliance |
| `Get-MissingTagsReport.ps1` | Missing tags aggregated by RG and tag |
| `Get-RbacAuditReport.ps1` | Privileged roles, orphaned assignments, guests |
| `Get-PolicyComplianceReport.ps1` | Non-compliant resources by policy assignment |
| `Get-ManagementLockReport.ps1` | Lock inventory + unprotected-RG detection |

### cleanup
| Script | Purpose |
|---|---|
| `Remove-UnattachedDisks.ps1` | Delete aged unattached managed disks |
| `Remove-UnusedSnapshots.ps1` | Delete aged snapshots |
| `Remove-OldResourceGroups.ps1` | Guarded removal of temporary resource groups |
| `Get-ZombieResources.ps1` | Resource Graph sweep for cost-leaking orphans |
| `New-ResourceCleanupReport.ps1` | Zombie summary grouped by category and RG |

### reports
| Script | Purpose |
|---|---|
| `Export-AzureInventoryReport.ps1` | Full Resource Graph inventory + type summary |
| `Invoke-ResourceGraphReport.ps1` | Ad-hoc Resource Graph KQL runner |
| `Export-MonthlyCostReport.ps1` | Cost Management report grouped by RG/service/type |
| `Get-SubscriptionHealthReport.ps1` | Provider, limits, and posture checks |

## Shared module (`shared/AzToolkit.Common`)

| Area | Functions |
|---|---|
| Logging | `Initialize-ToolkitLog`, `Write-ToolkitLog`, `Get-ToolkitCorrelationId` |
| Authentication | `Connect-ToolkitAzure`, `Test-ToolkitAzureConnection` |
| Resilience | `Invoke-WithRetry`, `Test-RetryableError` |
| Configuration | `Get-ToolkitConfig` (JSON + environment overlays) |
| Export | `Export-ToolkitCsv`, `Export-ToolkitJson`, `Get-ToolkitOutputPath` |

Logs are JSON lines - one parseable object per event, stamped with a correlation ID:

```json
{"timestamp":"2026-08-10T14:22:55.120Z","level":"Info","message":"Stopping VM","correlationId":"6c1f3bbc-...","script":"Stop-AzureVm.ps1","data":{"vm":"web-01"}}
```

## Azure Automation runbooks

Self-contained runbooks using the Automation Account's **system-assigned managed
identity** - scheduled VM start/stop, disk cleanup (report-only by default), and a Key
Vault expiry notifier with optional Teams webhook. Deployment steps, required roles,
and how they deliberately differ from the CLI scripts:
[automation-runbooks/README.md](automation-runbooks/README.md).

## Azure CLI scripts

Bash + JMESPath counterparts for flagship scenarios (VM operations, orphan finder, NSG
audit, Resource Graph inventory, Key Vault expiry) with dry-run-by-default semantics:
[azure-cli/README.md](azure-cli/README.md).

## Testing

```powershell
Install-Module Pester -MinimumVersion 6.0 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-Pester ./tests
```

Everything runs **offline** - unit tests mock the Az cmdlets, and the conformance suite
validates all 43 scripts by AST analysis (help completeness, approved verbs,
ShouldProcess on destructive verbs, exit-code discipline, shared-module import) plus a
repo-wide PSScriptAnalyzer gate. New scripts are discovered and enforced automatically.
Details: [tests/README.md](tests/README.md).

## Contributing & standards

- [docs/coding-standards.md](docs/coding-standards.md) - the enforced contract
- [docs/templates/script-template.ps1](docs/templates/script-template.ps1) - start here for new scripts
- [CONTRIBUTING.md](CONTRIBUTING.md) - workflow and PR checklist
- [docs/ROADMAP.md](docs/ROADMAP.md) - where this is going

## License

[MIT](LICENSE)
