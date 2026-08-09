#!/usr/bin/env bash
# Shared helpers for the azure-cli toolkit scripts. Source, don't execute:
#   SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
#   source "$SCRIPT_DIR/lib/common.sh"

# Timestamped status line to stderr (stdout stays clean for data).
log() {
    printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2
}

warn() {
    printf '[%s] WARNING: %s\n' "$(date +%H:%M:%S)" "$*" >&2
}

# die <message> [exit-code]
die() {
    local message=$1
    local code=${2:-1}
    printf 'ERROR: %s\n' "$message" >&2
    exit "$code"
}

# Guard: fail fast when there is no Azure CLI session.
require_az_login() {
    command -v az >/dev/null 2>&1 || die "Azure CLI (az) is not installed." 2
    az account show >/dev/null 2>&1 || die "Not logged in to Azure. Run 'az login' first." 2
}

# Guard: fail fast when a required az extension is missing.
require_az_extension() {
    local extension=$1
    az extension show --name "$extension" >/dev/null 2>&1 ||
        die "Azure CLI extension '$extension' is required. Install it with: az extension add --name $extension" 2
}

# confirm <prompt> - returns 0 only on an explicit yes.
confirm() {
    local reply
    read -r -p "$1 [y/N] " reply
    [[ $reply =~ ^[Yy]$ ]]
}
