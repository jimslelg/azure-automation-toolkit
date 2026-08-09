# Azure CLI Scripts

Bash counterparts to a few flagship PowerShell scenarios, for teams that live in the
`az` CLI. Each script demonstrates JMESPath querying and safe shell patterns rather
than duplicating all 40+ PowerShell scripts.

| Script | Mirrors | Notes |
|---|---|---|
| `vm-operations.sh` | `compute/Start\|Stop\|Restart-AzureVm.ps1` | Dry-run default; `-x` to execute |
| `find-orphaned-resources.sh` | `cleanup/Get-ZombieResources.ps1` | Unattached disks, unused NICs, free PIPs |
| `nsg-audit.sh` | `networking/Get-NsgAuditReport.ps1` | Exit 3 when sensitive ports are exposed |
| `resource-inventory.sh` | `reports/Export-AzureInventoryReport.ps1` | Resource Graph; needs `resource-graph` extension |
| `keyvault-expiry-report.sh` | `keyvault/Get-*ExpirationReport.ps1` | Exit 3 when findings exist |

## Conventions

- `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`
- `usage()` heredoc; `-h` always works; unknown flags exit 2
- **Destructive operations default to dry-run** and require an explicit `-x` to execute
- Status messages go to **stderr** (`log`/`warn` in `lib/common.sh`); stdout carries data,
  so `script.sh > out.tsv` stays clean
- Meaningful exit codes: 0 ok, 2 usage/login error, 3 findings or partial failure
- All scripts pass ShellCheck (enforced in CI)

## Prerequisites

```bash
az login
az account set --subscription <id>

# resource-inventory.sh only:
az extension add --name resource-graph

# nsg-audit.sh uses jq for JSON handling:
brew install jq   # or apt-get install jq
```
