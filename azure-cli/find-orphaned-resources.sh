#!/usr/bin/env bash
#
# find-orphaned-resources.sh - report unattached disks, unused NICs, and
# unassociated public IPs that quietly accrue cost.
#
# Azure CLI counterpart to powershell/cleanup/Get-ZombieResources.ps1. Read-only.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=azure-cli/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: find-orphaned-resources.sh [-o <table|tsv|json>] [-h]

Reports, for the current subscription:
  - Managed disks with diskState == 'Unattached'
  - NICs attached to neither a VM nor a private endpoint
  - Public IPs with no IP configuration (unassociated)

Options:
  -o <format>   Output format: table (default), tsv, or json
  -h            Show this help

Examples:
  find-orphaned-resources.sh
  find-orphaned-resources.sh -o tsv > orphans.tsv
EOF
}

OUTPUT=table
while getopts ':o:h' flag; do
    case "$flag" in
        o) OUTPUT=$OPTARG ;;
        h) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done
case "$OUTPUT" in table|tsv|json) ;; *) die "Invalid output format '$OUTPUT'" 2 ;; esac

require_az_login

log "Scanning for unattached managed disks..."
echo "=== Unattached managed disks ==="
# diskState is authoritative; managedBy stays empty for never-attached disks.
az disk list \
    --query "[?diskState == 'Unattached'].{name:name, resourceGroup:resourceGroup, sizeGb:diskSizeGB, sku:sku.name, created:timeCreated}" \
    --output "$OUTPUT"

log "Scanning for unused NICs..."
echo "=== NICs with no VM and no private endpoint ==="
az network nic list \
    --query "[?virtualMachine == null && privateEndpoint == null].{name:name, resourceGroup:resourceGroup, privateIp:ipConfigurations[0].privateIPAddress, location:location}" \
    --output "$OUTPUT"

log "Scanning for unassociated public IPs..."
echo "=== Public IPs with no association ==="
az network public-ip list \
    --query "[?ipConfiguration == null].{name:name, resourceGroup:resourceGroup, ip:ipAddress, sku:sku.name, method:publicIPAllocationMethod}" \
    --output "$OUTPUT"

log "Done. Review before deleting - some orphans are intentional (DR, reserved IPs)."
