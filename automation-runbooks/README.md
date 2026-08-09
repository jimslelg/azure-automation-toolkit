# Azure Automation Runbooks

Sample runbooks designed for an Azure Automation Account with a **system-assigned
managed identity**. They differ deliberately from the scripts in `powershell/`:

| Concern | `powershell/` scripts | Runbooks |
|---|---|---|
| Authentication | `Connect-ToolkitAzure` (auto-detect) | `Disable-AzContextAutosave -Scope Process` + `Connect-AzAccount -Identity` |
| Dependencies | `AzToolkit.Common` via relative path | Self-contained; Az modules from the Automation Account only |
| Output | Objects to pipeline + JSON-lines log file | `Write-Output` (job stream) / `Write-Verbose` |
| Safety | `-WhatIf` (ShouldProcess) | `-ReportOnly` boolean parameter (jobs have no interactive confirmation) |
| Failure | Exit codes 0-5 | `throw` → job status Failed (exit codes are meaningless in jobs) |

## Runbooks

| Runbook | Schedule suggestion | Purpose |
|---|---|---|
| `Start-TaggedVms-Runbook.ps1` | Weekdays 07:00 | Starts VMs tagged `AutoSchedule=business-hours` |
| `Stop-TaggedVms-Runbook.ps1` | Weekdays 19:00 | Deallocates the same VMs after hours |
| `Remove-UnattachedDisks-Runbook.ps1` | Weekly | Deletes long-unattached managed disks (`ReportOnly=$true` by default) |
| `Send-CertificateExpiryReport-Runbook.ps1` | Daily | Key Vault cert/secret expiry report, optional Teams webhook |

## Deployment

```powershell
$aa = @{ ResourceGroupName = 'rg-ops'; AutomationAccountName = 'aa-ops' }

# 1. Import a runbook (PowerShell 7.2 runtime)
Import-AzAutomationRunbook @aa -Name 'Stop-TaggedVms-Runbook' `
    -Path ./automation-runbooks/Stop-TaggedVms-Runbook.ps1 -Type PowerShell72 -Published

# 2. Grant the Automation Account's managed identity the needed role
$identity = (Get-AzAutomationAccount @aa).Identity.PrincipalId
New-AzRoleAssignment -ObjectId $identity -RoleDefinitionName 'Virtual Machine Contributor' `
    -Scope "/subscriptions/<subscription-id>"

# 3. Create and link a schedule
New-AzAutomationSchedule @aa -Name 'weekdays-evening' -StartTime '19:00' `
    -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday -WeekInterval 1 -TimeZone 'America/Toronto'
Register-AzAutomationScheduledRunbook @aa -RunbookName 'Stop-TaggedVms-Runbook' -ScheduleName 'weekdays-evening'
```

Required Az modules (add under Automation Account → Modules, runtime 7.2):
`Az.Accounts`, `Az.Compute`, `Az.KeyVault`.

## Roles per runbook

| Runbook | Minimum role for the managed identity |
|---|---|
| Start/Stop-TaggedVms | Virtual Machine Contributor |
| Remove-UnattachedDisks | Contributor (or a custom role scoped to `Microsoft.Compute/disks/*`) |
| Send-CertificateExpiryReport | Key Vault Reader + Key Vault Secrets User (data plane) |

## Using AzToolkit.Common from runbooks (optional)

The runbooks are intentionally standalone so they work out of the box. If you want the
shared module in an Automation Account, package and upload it — the Azure DevOps
pipeline's Publish stage produces exactly this zip:

```powershell
# The zip must contain a folder named AzToolkit.Common with the psd1 at its root
Copy-Item -Path ./shared -Destination ./AzToolkit.Common -Recurse
Compress-Archive -Path ./AzToolkit.Common -DestinationPath AzToolkit.Common.zip
New-AzAutomationModule @aa -Name 'AzToolkit.Common' -ContentLinkUri '<blob-url-of-zip>'
```

After import, a runbook can `Import-Module AzToolkit.Common` by name.
