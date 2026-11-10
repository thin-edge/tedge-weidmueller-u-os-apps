# Shared client for the u-OS HTTP APIs (Data Hub variables and Administration
# API), sourced by the scripts of this add-on. Configuration comes from the
# container environment (app settings DATA_HUB_CLIENT_ID / _SECRET).
#
# These APIs report values of the controller itself (firmware, disks, network,
# system logs, nameplate, LED states), which /sys or /proc inside this
# container can't see.

# Scripts run via sudo (log plugins, reboot command) get a reset environment,
# and "#!/command/with-contenv" doesn't work there (sudo's secure_path lacks
# /command). Read missing DATA_HUB_* settings from the s6 container
# environment directly.
for _uos_var in DATA_HUB_HOST DATA_HUB_CLIENT_ID DATA_HUB_CLIENT_SECRET DATA_HUB_INSECURE; do
    eval "_uos_val=\${$_uos_var:-}"
    if [ -z "$_uos_val" ] && [ -r "/run/s6/container_environment/$_uos_var" ]; then
        eval "$_uos_var=\$(cat \"/run/s6/container_environment/\$_uos_var\")"
    fi
done
unset _uos_var _uos_val

DATA_HUB_HOST="${DATA_HUB_HOST:-https://host.docker.internal}"
DATA_HUB_CLIENT_ID="${DATA_HUB_CLIENT_ID:-}"
DATA_HUB_CLIENT_SECRET="${DATA_HUB_CLIENT_SECRET:-}"
DATA_HUB_INSECURE="${DATA_HUB_INSECURE:-true}"

UOS_ADM_API="/u-os-adm/api/v1"
UOS_HUB_API="/u-os-hub/api/v1"

uos_configured() {
    [ -n "$DATA_HUB_CLIENT_ID" ] && [ -n "$DATA_HUB_CLIENT_SECRET" ]
}

# kept for existing callers
data_hub_configured() {
    uos_configured
}

uos_curl() {
    if [ "$DATA_HUB_INSECURE" = "true" ]; then
        curl -sk --max-time 30 "$@"
    else
        curl -s --max-time 30 "$@"
    fi
}

# uos_get_token <scope>: prints an access token for exactly this scope.
#
# One token per scope: if the client lacks a single scope, the token endpoint
# rejects the whole request, so only the feature needing that scope fails.
# Cached in a file per user and scope: callers run in command-substitution
# subshells (a variable would be lost), and log plugins / reboot run as root
# via sudo, which must not create files the tedge user can't replace.
uos_get_token() {
    scope="$1"
    uos_configured || return 1

    cache="${TMPDIR:-/tmp}/u-os-token-$(id -u)-$scope"
    if [ -s "$cache" ]; then
        cat "$cache"
        return 0
    fi

    # u-OS clients default to 'client_secret_basic' (credentials in the
    # Authorization header) and reject 'client_secret_post'. Try basic first,
    # fall back to post for clients configured that way.
    response=$(uos_curl -X POST "$DATA_HUB_HOST/oauth2/token" \
        -u "$DATA_HUB_CLIENT_ID:$DATA_HUB_CLIENT_SECRET" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "scope=$scope") || response=""
    token=$(printf '%s' "$response" | jq -r '.access_token // empty' 2>/dev/null)

    if [ -z "$token" ]; then
        response=$(uos_curl -X POST "$DATA_HUB_HOST/oauth2/token" \
            --data-urlencode "grant_type=client_credentials" \
            --data-urlencode "client_id=$DATA_HUB_CLIENT_ID" \
            --data-urlencode "client_secret=$DATA_HUB_CLIENT_SECRET" \
            --data-urlencode "scope=$scope") || response=""
        token=$(printf '%s' "$response" | jq -r '.access_token // empty' 2>/dev/null)
    fi

    if [ -z "$token" ]; then
        # stderr: this runs inside $(...), stdout would become the value
        printf '%s\n' "[u-os-api] no access token for scope '$scope' (is it enabled for the client in u-OS?)" >&2
        return 1
    fi
    (umask 077; printf '%s' "$token" > "$cache.$$") && mv -f "$cache.$$" "$cache"
    printf '%s' "$token"
}

# uos_request <method> <path> <scope> [extra curl args...]
# Prints the response body and returns 0 on HTTP 2xx. Retries once with a
# fresh token on 401/403, as the cached token may have expired.
uos_request() {
    method="$1"; path="$2"; scope="$3"; shift 3

    for _uos_attempt in 1 2; do
        token=$(uos_get_token "$scope") || return 1
        response=$(uos_curl -X "$method" -w '\n%{http_code}' \
            "$DATA_HUB_HOST$path" -H "Authorization: Bearer $token" "$@") || response=""
        status=$(printf '%s' "$response" | tail -n 1)

        case "$status" in
            2??)
                printf '%s' "$response" | sed '$d'
                return 0
                ;;
            401|403)
                rm -f "${TMPDIR:-/tmp}/u-os-token-$(id -u)-$scope"
                ;;
            *)
                return 1
                ;;
        esac
    done
    return 1
}

# uos_adm_get <path below /u-os-adm/api/v1> <scope>
uos_adm_get() {
    uos_request GET "$UOS_ADM_API$1" "$2"
}

# data_hub_get_variable <provider> <key> -> prints the value
data_hub_get_variable() {
    response=$(uos_request GET "$UOS_HUB_API/providers/$1/variables/$2" hub.variables.readonly) || return 1
    value=$(printf '%s' "$response" | jq -r '.value // empty' 2>/dev/null)
    [ -n "$value" ] || return 1
    printf '%s' "$value"
}
