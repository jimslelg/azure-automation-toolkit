# Contributing

Thanks for your interest in improving the Azure Automation Toolkit. This project aims to be a
realistic, production-grade reference for Azure operations automation — contributions are held
to the same bar.

## Getting started

1. Fork and clone the repository.
2. Install prerequisites:
   - [PowerShell 7.0+](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell)
   - `Install-Module Az, Pester, PSScriptAnalyzer -Scope CurrentUser`
   - [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) and
     [ShellCheck](https://www.shellcheck.net/) (for `azure-cli/` contributions)
3. Create a feature branch: `git checkout -b feature/<short-description>`

## Before you open a PR

Run the full local validation — CI runs exactly the same checks and will reject anything that fails:

```powershell
# Lint (must return zero findings)
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1

# Tests (must be fully green)
Invoke-Pester ./tests
```

```bash
# Bash scripts only
shellcheck azure-cli/*.sh
```

## Adding a new script

1. Start from `docs/templates/script-template.ps1` — it encodes every convention.
2. Read `docs/coding-standards.md`; the conformance suite enforces it mechanically
   (comment-based help, approved verbs, `SupportsShouldProcess` for destructive verbs,
   exit-code discipline, etc.).
3. Place the script in the matching `powershell/<category>/` folder.
4. Add a documentation page based on `docs/templates/script-doc-template.md` if the script
   has non-obvious behavior.
5. The conformance tests discover new scripts automatically — no test registration needed.

## Adding shared module functions

1. One function per file, under the matching `shared/<area>/` folder.
2. Export it in **both** `shared/AzToolkit.Common.psm1` (`Export-ModuleMember`) and
   `shared/AzToolkit.Common.psd1` (`FunctionsToExport`).
3. Add unit tests under `tests/unit/` — mock all Az cmdlets; tests must not require an
   Azure connection.

## Commit style

Conventional Commits:

```
feat(compute): add idle VM detection script
fix(shared): handle empty config overlay files
docs: expand Key Vault backup walkthrough
test: cover retry jitter bounds
```

## Pull request checklist

- [ ] Lint and tests pass locally
- [ ] New scripts follow the template and coding standards
- [ ] Destructive operations support `-WhatIf` (or `-ReportOnly` for runbooks)
- [ ] No secrets, subscription IDs, or tenant IDs committed
- [ ] Documentation updated where behavior changed
