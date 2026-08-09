# Script-Name.ps1

> One-line summary (matches the script's `.SYNOPSIS`).

## Overview

What the script does, whether it is read-only or state-changing, and the problem it solves
in day-to-day cloud operations.

## Prerequisites

- **PowerShell**: 7.0+
- **Modules**: Az.Accounts, Az.<Service>
- **Azure RBAC**: minimum role required (e.g. `Reader`, `Virtual Machine Contributor`)
- **Other**: anything else (Log Analytics workspace, tag conventions, etc.)

## Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| `SubscriptionId` | string | No | current context | Target subscription |
| ... | | | | |

## Usage

```powershell
# Basic usage
./Script-Name.ps1 -SubscriptionId <guid>

# Preview (state-changing scripts only)
./Script-Name.ps1 -SubscriptionId <guid> -WhatIf

# Export results
./Script-Name.ps1 -ExportPath ./output -ExportFormat Json
```

## Output

Describe the shape of the objects emitted to the pipeline:

| Property | Type | Description |
|----------|------|-------------|
| `Name` | string | Resource name |
| ... | | |

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General failure |
| 2 | Authentication failure |
| 3 | Partial failure |
| 4 | Invalid parameters/configuration |
| 5 | No matching resources |

## Notes / caveats

Rate limits, long-running behavior, cost of API calls, known limitations.
