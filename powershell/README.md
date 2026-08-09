# PowerShell Scripts

43 operational scripts in 9 categories. The full catalog with one-line descriptions is
in the [root README](../README.md#script-catalog); per-script documentation lives in the
scripts themselves as comment-based help:

```powershell
Get-Help ./compute/Get-IdleVms.ps1 -Full        # parameters, examples, exit codes
Get-Help ./cleanup/Remove-UnattachedDisks.ps1 -Examples
```

## Shared behavior

Every script here follows the same contract (enforced by `tests/conformance/`):

- Emits result objects to the pipeline; formatting is the caller's job
- Writes a JSON-lines log with a correlation ID to `./logs/`
- Report scripts accept `-ExportPath <dir>` and `-ExportFormat Csv|Json`
- Destructive scripts support `-WhatIf`/`-Confirm` and skip items on per-item failure
  (exit code 3 signals partial failure)
- Azure calls retry transient errors (429/5xx/timeouts) with exponential backoff
- Authentication is automatic: managed identity → service principal env vars →
  existing context → interactive

See [docs/coding-standards.md](../docs/coding-standards.md) for the contract and
[docs/templates/script-template.ps1](../docs/templates/script-template.ps1) to add a
new script.
