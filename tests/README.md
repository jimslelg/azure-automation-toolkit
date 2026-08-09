# Tests

Two complementary suites, both runnable offline — no Azure subscription, no Az modules,
and no credentials are required.

## Unit tests (`tests/unit/`)

Cover every public function of the `AzToolkit.Common` module. Az cmdlets
(`Connect-AzAccount`, `Get-AzContext`, `Set-AzContext`) are stubbed inside the module
scope and mocked with Pester, so authentication-mode detection, retry classification,
config merging, logging output, and exporters are all verified without touching Azure.
All file operations use Pester's `$TestDrive`.

## Conformance tests (`tests/conformance/`)

The enforcement mechanism behind `docs/coding-standards.md`:

- **ScriptConformance.Tests.ps1** discovers every `*.ps1` under `powershell/` and
  `automation-runbooks/` automatically (new scripts need no test registration) and
  validates each one by AST analysis only — scripts are never executed. Checks include
  comment-based help completeness, approved verbs, `#Requires` directives,
  `CmdletBinding`, `SupportsShouldProcess` for destructive verbs (`-ReportOnly` for
  runbooks), shared-module import, and exit-code discipline.
- **ScriptAnalyzer.Tests.ps1** runs PSScriptAnalyzer over the whole repository with the
  shared ruleset in `PSScriptAnalyzerSettings.psd1` and fails on any finding.

## Running

```powershell
Install-Module Pester -MinimumVersion 6.0 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser

# Everything (same as CI)
Invoke-Pester -Configuration (New-PesterConfiguration -Hashtable (Import-PowerShellDataFile ./tests/PesterConfiguration.psd1))

# Quick local run
Invoke-Pester ./tests
```

## Known limitation: no integration tests

The automation scripts themselves are validated by linting and conformance checks, not
by execution — running them for real requires a live subscription with disposable
fixtures. An integration harness (Bicep-deployed sandbox, torn down per run) is on the
roadmap (`docs/ROADMAP.md`, v1.1).
