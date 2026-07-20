#!/bin/sh
# Shared u-OS Data Hub REST API client, sourced by scripts that need to read
# Data Hub variables (OAuth2 client-credentials token + variable lookup).
# Not executable on its own - expects the sourcing script to have `set -eu`.

DATA_HUB_HOST="${DATA_HUB_HOST:-https://host.docker.internal}"
DATA_HUB_CLIENT_ID="${DATA_HUB_CLIENT_ID:-}"
DATA_HUB_CLIENT_SECRET="${DATA_HUB_CLIENT_SECRET:-}"
DATA_HUB_INSECURE="${DATA_HUB_INSECURE:-true}"
DATA_HUB_TOKEN_CACHE="${TMPDIR:-/tmp}/data-hub-token"

log() {
    printf '%s\n' "[${LOG_PREFIX:-data-hub}] $*" >&2
}

json_escape() {
    printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

data_hub_curl() {
    if [ "$DATA_HUB_INSECURE" = "true" ]; then
        curl -sk "$@"
    else
        curl -s "$@"
    fi
}

data_hub_get_token() {
    [ -n "$DATA_HUB_CLIENT_ID" ] && [ -n "$DATA_HUB_CLIENT_SECRET" ] || return 1

    # Cached in a file rather than a variable: each call below runs in its
    # own command-substitution subshell, so a plain variable assignment
    # would not be visible to the next caller. Shared across all scripts
    # that source this lib, so they don't re-authenticate independently.
    if [ -s "$DATA_HUB_TOKEN_CACHE" ]; then
        cat "$DATA_HUB_TOKEN_CACHE"
        return 0
    fi

    response=$(data_hub_curl -X POST "$DATA_HUB_HOST/oauth2/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_id=$DATA_HUB_CLIENT_ID" \
        --data-urlencode "client_secret=$DATA_HUB_CLIENT_SECRET" \
        --data-urlencode "scope=hub.variables.readonly") || return 1

    token=$(printf '%s' "$response" | jq -r '.access_token // empty' 2>/dev/null)
    [ -n "$token" ] || return 1
    printf '%s' "$token" > "$DATA_HUB_TOKEN_CACHE"
    printf '%s' "$token"
}

# data_hub_get_variable <key> <provider>
data_hub_get_variable() {
    key="$1"
    provider="$2"
    token=$(data_hub_get_token) || return 1

    response=$(data_hub_curl "$DATA_HUB_HOST/u-os-hub/api/v1/providers/$provider/variables/$key" \
        -H "Authorization: Bearer $token") || return 1

    value=$(printf '%s' "$response" | jq -r '.value // empty' 2>/dev/null)
    [ -n "$value" ] || return 1
    printf '%s' "$value"
}
