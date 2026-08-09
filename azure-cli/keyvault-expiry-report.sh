#!/usr/bin/env bash
#
# keyvault-expiry-report.sh - report Key Vault certificates and secrets that are
# expired or expiring within a warning window.
#
# Azure CLI counterpart to powershell/keyvault/Get-*ExpirationReport.ps1. Read-only.

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=azure-cli/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
    cat <<'EOF'
Usage: keyvault-expiry-report.sh [-v <vault-name>] [-d <days>] [-h]

Reports certificates and secrets that are expired or expire within the warning
window, across all vaults you can read (or one vault with -v).

Options:
  -v <vault>   Limit to one Key Vault
  -d <days>    Warning window in days (default 30)
  -h           Show this help

Exit codes: 0 nothing expiring, 3 findings exist, 2 usage/login error.

Examples:
  keyvault-expiry-report.sh
  keyvault-expiry-report.sh -v kv-app-prod -d 60
EOF
}

VAULT=""
DAYS=30
while getopts ':v:d:h' flag; do
    case "$flag" in
        v) VAULT=$OPTARG ;;
        d) DAYS=$OPTARG ;;
        h) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done
[[ $DAYS =~ ^[0-9]+$ ]] || die "-d expects a number of days" 2

require_az_login

# Portable (BSD/GNU date) cutoff in epoch seconds.
NOW=$(date +%s)
CUTOFF=$((NOW + DAYS * 86400))

if [[ -n $VAULT ]]; then
    VAULTS=$VAULT
else
    VAULTS=$(az keyvault list --query '[].name' --output tsv)
fi
[[ -n $VAULTS ]] || { warn "No Key Vaults visible to this account."; exit 0; }

FINDINGS=0

report_items() {
    local vault=$1 kind=$2 rows=$3
    while IFS=$'\t' read -r name expires; do
        [[ -n $name && -n $expires && $expires != "None" ]] || continue
        # attributes.expires is ISO8601; keep the date part and compare as epoch.
        local expiry_epoch
        expiry_epoch=$(date -j -f '%Y-%m-%d' "${expires:0:10}" +%s 2>/dev/null ||
            date -d "${expires:0:10}" +%s 2>/dev/null) || continue
        if ((expiry_epoch <= CUTOFF)); then
            local days_left=$(((expiry_epoch - NOW) / 86400))
            local status="EXPIRING"
            ((expiry_epoch < NOW)) && status="EXPIRED"
            printf '%-9s %-12s %-35s vault=%-24s expires=%s (%s days)\n' \
                "$status" "$kind" "$name" "$vault" "${expires:0:10}" "$days_left"
            FINDINGS=$((FINDINGS + 1))
        fi
    done <<<"$rows"
}

for vault in $VAULTS; do
    log "Scanning vault: $vault"
    CERTS=$(az keyvault certificate list --vault-name "$vault" \
        --query '[].[name, attributes.expires]' --output tsv 2>/dev/null) ||
        { warn "Cannot list certificates in '$vault' (missing data-plane permission?)"; CERTS=""; }
    [[ -n $CERTS ]] && report_items "$vault" certificate "$CERTS"

    SECRETS=$(az keyvault secret list --vault-name "$vault" \
        --query '[].[name, attributes.expires]' --output tsv 2>/dev/null) ||
        { warn "Cannot list secrets in '$vault' (missing data-plane permission?)"; SECRETS=""; }
    [[ -n $SECRETS ]] && report_items "$vault" secret "$SECRETS"
done

if ((FINDINGS > 0)); then
    log "$FINDINGS item(s) expired or expiring within $DAYS day(s)."
    exit 3
fi
log "Nothing expires within $DAYS day(s)."
