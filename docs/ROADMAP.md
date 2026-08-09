# Roadmap

## v1.0 — Foundation (current)

- [x] Repository structure, coding standards, script/doc templates
- [x] `AzToolkit.Common` shared module (auth, logging, retry, config, exporters)
- [x] Pester unit + conformance suites, PSScriptAnalyzer ruleset
- [x] GitHub Actions CI and Azure DevOps multi-stage pipeline
- [x] 43 production scripts across compute, storage, networking, keyvault, sql,
      monitoring, governance, cleanup, and reports
- [x] Azure Automation runbook samples (Managed Identity)
- [x] Azure CLI (bash) flagship scripts

## v1.1 — Hardening

- [ ] Integration test harness against a disposable sandbox subscription (Bicep-deployed
      fixtures, torn down after each run)
- [ ] Publish `AzToolkit.Common` to the PowerShell Gallery
- [ ] Signed releases with tagged versions and a CHANGELOG
- [ ] Parallel processing (`ForEach-Object -Parallel`) for large-fleet operations with
      throttle limits

## v1.2 — Coverage expansion

- [ ] App Service / Functions operations (slot swaps, scale rules, cert bindings)
- [ ] AKS operations (node pool scaling, version audit)
- [ ] Entra ID reports (stale service principals, credential expiry)
- [ ] Defender for Cloud posture export
- [ ] Azure Backup / Site Recovery compliance reports

## v2.0 — Platform integration

- [ ] Deploy-as-a-product: Bicep templates that stand up an Automation Account with all
      runbooks, schedules, and role assignments in one deployment
- [ ] Event-driven automation samples (Event Grid → Function → toolkit script)
- [ ] Notification connectors beyond Teams (Slack, ServiceNow incident creation)
- [ ] Power BI template consuming the toolkit's report outputs

Suggestions welcome — open an issue with the `enhancement` label.
