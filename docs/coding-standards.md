# Coding Standards

These standards apply to every script in `powershell/` and `automation-runbooks/`. They are
machine-enforced by the conformance test suite (`tests/conformance/`) and PSScriptAnalyzer
(`PSScriptAnalyzerSettings.psd1` at the repo root) — CI fails on any violation.

## Naming

- Script files use `Verb-Noun.ps1` with an [approved PowerShell verb](https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands)
  (`Get-IdleVms.ps1`, `Remove-UnattachedDisks.ps1`). The conformance suite validates the verb
  against `Get-Verb`.
- Shared module functions use the `Toolkit` noun prefix (`Write-ToolkitLog`, `Connect-ToolkitAzure`)
  to avoid collisions with Az cmdlets.
- Runbooks carry a `-Runbook` suffix (`Start-TaggedVms-Runbook.ps1`) so their different
  conventions (see below) are visible at a glance.
- Parameters are PascalCase; local variables are camelCase.

## Required script structure

Every script must contain, in order:

1. `#Requires -Version 7.0` and `#Requires -Modules` for each Az module it uses.
2. Comment-based help with at minimum `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER` (for every
   parameter), one `.EXAMPLE`, and `.NOTES` documenting author, version, and exit codes.
3. `[CmdletBinding()]` — with `SupportsShouldProcess` when the script changes state (see below).
4. A `param()` block with validation attributes (`ValidateSet`, `ValidateRange`,
   `ValidatePattern`, `ValidateNotNullOrEmpty`) on every parameter where a constraint exists.
5. `$ErrorActionPreference = 'Stop'` before any work happens.
6. Module import: `Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'AzToolkit.Common.psd1') -Force`
7. A `try/catch/finally` skeleton that maps failures to the exit-code table and always logs
   completion. See `docs/templates/script-template.ps1` for the canonical skeleton.

## -WhatIf / ShouldProcess policy

`SupportsShouldProcess` is **mandatory** when the script's verb is one of:

`Remove`, `Stop`, `Start`, `Restart`, `Set`, `New`, `Update`, `Restore`, `Clear`, `Disable`, `Enable`

Every state-changing call inside those scripts must be gated:

```powershell
if ($PSCmdlet.ShouldProcess($resource.Name, 'Stop VM')) {
    Stop-AzVM -Name $resource.Name -ResourceGroupName $resource.ResourceGroupName -Force
}
```

Read-only scripts (`Get-*`, `Export-*`, `Test-*`) use plain `[CmdletBinding()]`.

Runbooks are the exception: Azure Automation jobs have no interactive confirmation, so runbooks
use an explicit `-ReportOnly` boolean parameter (default `$true`) instead of ShouldProcess.

## Exit codes

| Code | Meaning | When |
|------|---------|------|
| 0 | Success | Everything processed without error |
| 1 | General failure | Unhandled/unexpected exception |
| 2 | Authentication failure | `Connect-ToolkitAzure` threw `AzToolkit.AuthenticationFailed` |
| 3 | Partial failure | Some items processed, some failed — details in the log |
| 4 | Invalid parameters or configuration | Bad input caught at validation time, or `AzToolkit.ConfigurationInvalid` |
| 5 | No matching resources | Only for scripts where an empty result is actionable; otherwise return 0 with a warning |

Scripts exit via a single `exit $exitCode` as the final statement — never `exit` mid-body.

## Output contract

- **Objects to the pipeline are the primary output.** Emit `[pscustomobject]` results so callers
  can filter, sort, and pipe. Never emit formatted text as data.
- File export is opt-in via `-ExportPath` (directory) and `-ExportFormat Csv|Json`, implemented
  with `Export-ToolkitCsv` / `Export-ToolkitJson` (timestamped filenames, logged).
- Logging must never leak into the pipeline: suppress non-data returns with `| Out-Null` or
  `$null =`.

## Logging

- Initialize once per script: `Initialize-ToolkitLog -ScriptName $MyInvocation.MyCommand.Name`.
- All operational messages go through `Write-ToolkitLog` (never bare `Write-Host`), which writes
  colored console output plus JSON-lines to `./logs/`. Attach structured context with `-Data`:

```powershell
Write-ToolkitLog -Message 'Stopping VM' -Data @{ vm = $vm.Name; resourceGroup = $vm.ResourceGroupName }
```

- Every run carries a correlation ID (auto-generated GUID) stamped on each log line.

## Error handling

- `$ErrorActionPreference = 'Stop'` globally; per-item loops use their own `try/catch` and count
  failures so one bad resource doesn't abort a fleet operation (exit 3 on partial failure).
- Transient Azure errors (429, 5xx, timeouts) are retried with `Invoke-WithRetry`; wrap the
  individual Azure call, not whole loops.
- Catch blocks log via `Write-ToolkitLog -Level Error -ErrorRecord $_` — never swallow errors
  silently.

## Azure CLI (bash) scripts

- `#!/usr/bin/env bash`, `set -euo pipefail`, `IFS=$'\n\t'`.
- A `usage()` heredoc; `-h` always prints it; unknown flags print usage and exit 2.
- Destructive operations default to dry-run; require `--no-dry-run` to act.
- Source `lib/common.sh` for `log`, `die`, `require_az_login`, `confirm`.
- Must pass ShellCheck with no findings.

## Style

Style is enforced by the formatting rules in `PSScriptAnalyzerSettings.psd1`: 4-space
indentation, opening brace on the same line, consistent whitespace, correct cmdlet casing.
Run the linter before pushing:

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```
