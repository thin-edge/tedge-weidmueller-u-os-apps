#!/bin/sh
# Shared u-OS Data Hub REST API client, sourced by scripts that need to read
# or write Data Hub variables (OAuth2 client-credentials token + variable
# lookup/update). Not executable on its own - expects the sourcing script to
# have `set -eu`.

DATA_HUB_HOST="${DATA_HUB_HOST:-https://host.docker.internal}"
DATA_HUB_CLIENT_ID="${DATA_HUB_CLIENT_ID:-}"
DATA_HUB_CLIENT_SECRET="${DATA_HUB_CLIENT_SECRET:-}"
DATA_HUB_INSECURE="${DATA_HUB_INSECURE:-true}"
DATA_HUB_TOKEN_CACHE="${TMPDIR:-/tmp}/data-hub-token"
# Scope requested for the OAuth2 token. Set to "hub.variables.readwrite"
# before calling data_hub_get_token/data_hub_set_variable if the caller needs
# to write; a readwrite token also satisfies reads, so scripts that mix
# read+write entries only need to decide this once at startup.
DATA_HUB_TOKEN_SCOPE="${DATA_HUB_TOKEN_SCOPE:-hub.variables.readonly}"

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
    # Keyed by scope so a readonly caller and a readwrite caller (e.g. the
    # inventory script vs. a measurement config with write-capable entries)
    # never hand each other a wrongly-scoped token.
    scope="${DATA_HUB_TOKEN_SCOPE:-hub.variables.readonly}"
    cache_file="${DATA_HUB_TOKEN_CACHE}.$(printf '%s' "$scope" | tr -c 'a-zA-Z0-9' '_')"

    if [ -s "$cache_file" ]; then
        cat "$cache_file"
        return 0
    fi

    response=$(data_hub_curl -X POST "$DATA_HUB_HOST/oauth2/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_id=$DATA_HUB_CLIENT_ID" \
        --data-urlencode "client_secret=$DATA_HUB_CLIENT_SECRET" \
        --data-urlencode "scope=$scope") || return 1

    token=$(printf '%s' "$response" | jq -r '.access_token // empty' 2>/dev/null)
    [ -n "$token" ] || return 1
    printf '%s' "$token" > "$cache_file"
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

# data_hub_list_variables <provider> [prefixes] [definition]
# Lists variables of a provider - raw JSON array response, unlike
# data_hub_get_variable this doesn't extract a single value since the shape
# depends on what the caller asked for. <prefixes> is an optional
# comma-separated list to filter by key prefix (empty/omitted = all).
# <definition> set to "true" includes each variable's access_type/data_type/
# experimental flag (useful to see which keys are actually writable before
# configuring a "w"/"rw" mapping entry).
data_hub_list_variables() {
    provider="$1"
    prefixes="${2:-}"
    definition="${3:-false}"
    token=$(data_hub_get_token) || return 1

    query=""
    [ -n "$prefixes" ] && query="prefixes=$prefixes"
    if [ "$definition" = "true" ]; then
        query="${query:+$query&}definition=true"
    fi

    url="$DATA_HUB_HOST/u-os-hub/api/v1/providers/$provider/variables"
    [ -n "$query" ] && url="$url?$query"

    data_hub_curl "$url" -H "Authorization: Bearer $token"
}

# data_hub_set_variable <provider> <key> <value>
# <value> must already be a valid JSON scalar (e.g. 42, true, "text" with
# the quotes included) - this function does not infer or convert types, same
# "dumb pass-through" contract as data_hub_get_variable not typing its output.
# Requires a token with the hub.variables.readwrite scope: set
# DATA_HUB_TOKEN_SCOPE=hub.variables.readwrite before calling this.
data_hub_set_variable() {
    provider="$1"
    key="$2"
    value="$3"
    token=$(data_hub_get_token) || return 1

    body=$(printf '{"key":"%s","value":%s}' "$(json_escape "$key")" "$value")

    http_code=$(data_hub_curl -o /dev/null -w '%{http_code}' -X POST \
        "$DATA_HUB_HOST/u-os-hub/api/v1/providers/$provider/variables/$key" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$body") || return 1

    case "$http_code" in
        2??) return 0 ;;
        405) log "data_hub_set_variable: '$key' on provider '$provider' is read-only (HTTP 405)"; return 1 ;;
        *) log "data_hub_set_variable: $provider/$key -> HTTP $http_code"; return 1 ;;
    esac
}
