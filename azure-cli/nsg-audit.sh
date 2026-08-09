#!/usr/bin/env bash
#
# nsg-audit.sh - flag NSG rules that allow inbound traffic from the internet
# to sensitive ports (SSH, RDP, databases, WinRM).
#
# Azure CLI counterpart to powershell/networking/Get-NsgAuditReport.ps1. Read-only.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=azure-cli/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: nsg-audit.sh [-g <resource-group>] [-h]

Flags inbound ALLOW rules whose source is open ('*', '0.0.0.0/0', 'Internet', 'Any')
in every NSG in scope. Reviewing which of those rules expose sensitive ports
(22, 3389, 1433, 3306, 5432, 5985, 5986) is the point of the audit.

Options:
  -g <group>   Limit the audit to one resource group
  -h           Show this help

Examples:
  nsg-audit.sh
  nsg-audit.sh -g rg-network-prod
EOF
}

RESOURCE_GROUP=""
while getopts ':g:h' flag; do
    case "$flag" in
        g) RESOURCE_GROUP=$OPTARG ;;
        h) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done

require_az_login

SCOPE_ARGS=()
[[ -n $RESOURCE_GROUP ]] && SCOPE_ARGS+=(--resource-group "$RESOURCE_GROUP")

# JMESPath: one row per open inbound allow rule across all NSGs in scope.
# sourceAddressPrefix covers the common single-value cases; the [] flattening
# merges every NSG's matching rules into one result set.
OPEN_RULES=$(az network nsg list "${SCOPE_ARGS[@]}" --query "
    [].{nsg: name, resourceGroup: resourceGroup, rules: securityRules[?
        access == 'Allow' &&
        direction == 'Inbound' &&
        (sourceAddressPrefix == '*' || sourceAddressPrefix == '0.0.0.0/0' || sourceAddressPrefix == 'Internet' || sourceAddressPrefix == 'Any')
    ].{rule: name, priority: priority, ports: destinationPortRange, portRanges: join(',', destinationPortRanges || \`[]\`)}}
    | [?length(rules) > \`0\`]" --output json)

if [[ $(jq 'length' <<<"$OPEN_RULES" 2>/dev/null || echo 0) -eq 0 ]]; then
    log "No open inbound allow rules found."
    exit 0
fi

SENSITIVE_PORTS=(22 3389 1433 3306 5432 5985 5986)

echo "=== Inbound ALLOW rules open to the internet ==="
FINDINGS=0
HIGH=0
while IFS=$'\t' read -r nsg group rule priority ports port_ranges; do
    all_ports="$ports"
    [[ -n $port_ranges && $port_ranges != "null" ]] && all_ports="$ports,$port_ranges"

    severity="Medium"
    for port in "${SENSITIVE_PORTS[@]}"; do
        if [[ $all_ports == "*" || ",$all_ports," == *",$port,"* ]]; then
            severity="HIGH"
            HIGH=$((HIGH + 1))
            break
        fi
    done
    FINDINGS=$((FINDINGS + 1))
    printf '%-8s nsg=%-30s rg=%-25s rule=%-30s priority=%-6s ports=%s\n' \
        "$severity" "$nsg" "$group" "$rule" "$priority" "$all_ports"
done < <(jq -r '.[] | .nsg as $n | .resourceGroup as $g | .rules[] | [$n, $g, .rule, (.priority|tostring), (.ports // "-"), (.portRanges // "-")] | @tsv' <<<"$OPEN_RULES")

log "$FINDINGS open inbound rule(s) found, $HIGH exposing sensitive ports."
if ((HIGH > 0)); then
    exit 3
fi
