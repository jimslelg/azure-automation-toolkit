#!/usr/bin/env bash
#
# resource-inventory.sh - subscription inventory via Azure Resource Graph:
# counts by type plus an optional full CSV export.
#
# Azure CLI counterpart to powershell/reports/Export-AzureInventoryReport.ps1. Read-only.
# Requires the resource-graph extension: az extension add --name resource-graph

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=azure-cli/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: resource-inventory.sh [-c <csv-file>] [-t <top-n>] [-h]

Prints resource counts by type (Azure Resource Graph) and optionally exports the
full inventory to CSV.

Options:
  -c <file>   Also export the full inventory (name, type, RG, location) to this CSV file
  -t <n>      Show only the top N types (default 25)
  -h          Show this help

Examples:
  resource-inventory.sh
  resource-inventory.sh -t 10 -c inventory.csv
EOF
}

CSV_FILE=""
TOP_N=25
while getopts ':c:t:h' flag; do
    case "$flag" in
        c) CSV_FILE=$OPTARG ;;
        t) TOP_N=$OPTARG ;;
        h) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done
[[ $TOP_N =~ ^[0-9]+$ ]] || die "-t expects a number" 2

require_az_login
require_az_extension resource-graph

log "Querying resource counts by type (top $TOP_N)..."
az graph query -q "
    Resources
    | summarize count=count() by type
    | order by count desc
    | take $TOP_N
" --query 'data[].{type:type, count:count}' --output table

TOTAL=$(az graph query -q 'Resources | count' --query 'data[0].Count' --output tsv)
log "Total resources in scope: $TOTAL"

if [[ -n $CSV_FILE ]]; then
    log "Exporting full inventory to $CSV_FILE..."
    echo 'name,type,resourceGroup,location,subscriptionId' >"$CSV_FILE"

    # Resource Graph pages at 1000 rows; loop with skip until exhausted.
    SKIP=0
    while true; do
        BATCH=$(az graph query -q "
            Resources
            | project name, type, resourceGroup, location, subscriptionId
            | order by name asc
        " --first 1000 --skip "$SKIP" \
            --query 'data[].[name, type, resourceGroup, location, subscriptionId]' --output tsv)
        [[ -n $BATCH ]] || break
        # TSV -> CSV with quoting to survive commas in names.
        awk -F'\t' '{ printf "\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"\n", $1, $2, $3, $4, $5 }' <<<"$BATCH" >>"$CSV_FILE"
        ROWS=$(wc -l <<<"$BATCH" | tr -d ' ')
        SKIP=$((SKIP + ROWS))
        log "  exported $SKIP row(s)..."
        ((ROWS < 1000)) && break
    done
    log "Inventory written to $CSV_FILE"
fi
