#!/usr/bin/env bash
#
# vm-operations.sh - start / stop / deallocate / restart / list Azure VMs by
# resource group or by tag, with dry-run as the default for state changes.
#
# Azure CLI counterpart to powershell/compute/{Start,Stop,Restart}-AzureVm.ps1.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=azure-cli/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: vm-operations.sh -a <action> [-g <resource-group>] [-t <tag=value>] [-n <vm-name>] [-x] [-h]

Actions:
  list        List VMs with power state (default scope: subscription)
  start       Start matching VMs
  stop        Stop matching VMs (OS shutdown, still billed)
  deallocate  Deallocate matching VMs (stops billing)
  restart     Restart matching VMs

Options:
  -a <action>      One of the actions above (required)
  -g <group>       Limit scope to a resource group
  -t <tag=value>   Select VMs by tag, e.g. -t AutoSchedule=business-hours
  -n <name>        Select a single VM by name (requires -g)
  -x               Execute. Without -x, state-changing actions run in DRY-RUN mode
  -h               Show this help

Examples:
  vm-operations.sh -a list
  vm-operations.sh -a deallocate -t AutoSchedule=business-hours        # dry run
  vm-operations.sh -a deallocate -t AutoSchedule=business-hours -x     # for real
  vm-operations.sh -a restart -g rg-app-prod -n web-01 -x
EOF
}

ACTION=""
RESOURCE_GROUP=""
TAG_FILTER=""
VM_NAME=""
DRY_RUN=true

while getopts ':a:g:t:n:xh' flag; do
    case "$flag" in
        a) ACTION=$OPTARG ;;
        g) RESOURCE_GROUP=$OPTARG ;;
        t) TAG_FILTER=$OPTARG ;;
        n) VM_NAME=$OPTARG ;;
        x) DRY_RUN=false ;;
        h) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done

[[ -n $ACTION ]] || { usage; exit 2; }
case "$ACTION" in
    list|start|stop|deallocate|restart) ;;
    *) die "Unknown action '$ACTION'" 2 ;;
esac
if [[ -n $VM_NAME && -z $RESOURCE_GROUP ]]; then
    die "-n requires -g <resource-group>" 2
fi

require_az_login

# Build the list of target VMs as tab-separated "name<TAB>resourceGroup" lines.
list_targets() {
    local scope_args=()
    [[ -n $RESOURCE_GROUP ]] && scope_args+=(--resource-group "$RESOURCE_GROUP")

    if [[ -n $TAG_FILTER ]]; then
        local tag_key=${TAG_FILTER%%=*}
        local tag_value=${TAG_FILTER#*=}
        # JMESPath: keep VMs whose tag map contains the key with the expected value.
        az vm list "${scope_args[@]}" \
            --query "[?tags.\"$tag_key\" == '$tag_value'].[name, resourceGroup]" \
            --output tsv
    elif [[ -n $VM_NAME ]]; then
        az vm show --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" \
            --query '[name, resourceGroup]' --output tsv | paste -s -
    else
        az vm list "${scope_args[@]}" --query '[].[name, resourceGroup]' --output tsv
    fi
}

if [[ $ACTION == list ]]; then
    scope_args=()
    [[ -n $RESOURCE_GROUP ]] && scope_args+=(--resource-group "$RESOURCE_GROUP")
    # -d adds powerState to each row.
    az vm list -d "${scope_args[@]}" \
        --query '[].{name:name, resourceGroup:resourceGroup, powerState:powerState, size:hardwareProfile.vmSize, location:location}' \
        --output table
    exit 0
fi

TARGETS=$(list_targets)
[[ -n $TARGETS ]] || { warn "No VMs matched the selection."; exit 0; }

COUNT=$(wc -l <<<"$TARGETS" | tr -d ' ')
log "$ACTION: $COUNT VM(s) selected"

FAILED=0
while IFS=$'\t' read -r name group; do
    if [[ $DRY_RUN == true ]]; then
        log "[DRY-RUN] Would $ACTION: $group/$name (pass -x to execute)"
        continue
    fi
    log "$ACTION: $group/$name"
    if ! az vm "$ACTION" --resource-group "$group" --name "$name" --no-wait; then
        warn "Failed to $ACTION $group/$name"
        FAILED=$((FAILED + 1))
    fi
done <<<"$TARGETS"

if ((FAILED > 0)); then
    die "$FAILED of $COUNT operation(s) failed" 3
fi
log "Done."
