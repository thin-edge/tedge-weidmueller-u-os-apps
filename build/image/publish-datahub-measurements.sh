#!/bin/sh
set -eu

LOG_PREFIX="datahub-measurements"
# shellcheck source=lib/data-hub-client.sh
. /usr/local/lib/data-hub-client.sh

DATA_HUB_VARIABLES="${DATA_HUB_VARIABLES:-}"
DATA_HUB_MEASUREMENT_PROVIDER="${DATA_HUB_MEASUREMENT_PROVIDER:-}"
DATA_HUB_POLL_INTERVAL="${DATA_HUB_POLL_INTERVAL:-10}"

is_number() {
    case "$1" in
        ''|*[!0-9.+-]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_configured() {
    [ -n "$DATA_HUB_VARIABLES" ] \
        && [ -n "$DATA_HUB_MEASUREMENT_PROVIDER" ] \
        && [ -n "$DATA_HUB_CLIENT_ID" ] \
        && [ -n "$DATA_HUB_CLIENT_SECRET" ]
}

build_measurement_payload() {
    payload=""
    old_ifs="$IFS"
    IFS=','
    for key in $DATA_HUB_VARIABLES; do
        IFS="$old_ifs"
        [ -n "$key" ] || continue

        if ! value=$(data_hub_get_variable "$key" "$DATA_HUB_MEASUREMENT_PROVIDER" 2>/dev/null); then
            log "Failed to fetch variable '$key', skipping this cycle"
            continue
        fi

        if ! is_number "$value"; then
            log "Variable '$key' has a non-numeric value ('$value'), skipping"
            continue
        fi

        fragment=$(printf '"%s":{"value":%s}' "$(json_escape "$key")" "$value")
        if [ -n "$payload" ]; then
            payload="$payload,$fragment"
        else
            payload="$fragment"
        fi
        IFS=','
    done
    IFS="$old_ifs"
    printf '%s' "$payload"
}

log "Starting Data Hub measurement bridge (poll interval: ${DATA_HUB_POLL_INTERVAL}s)"

disabled_logged=false
while true; do
    if ! is_configured; then
        if [ "$disabled_logged" = false ]; then
            log "Disabled: set DATA_HUB_VARIABLES, DATA_HUB_MEASUREMENT_PROVIDER and DATA_HUB_CLIENT_ID/SECRET to enable"
            disabled_logged=true
        fi
        sleep "$DATA_HUB_POLL_INTERVAL"
        continue
    fi
    disabled_logged=false

    fields=$(build_measurement_payload)
    if [ -n "$fields" ]; then
        if tedge mqtt pub "te/device/main///m/data_hub" "{$fields}" >/dev/null 2>&1; then
            log "Published data_hub measurement"
        else
            log "Failed to publish data_hub measurement"
        fi
    else
        log "No numeric values retrieved this cycle, nothing published"
    fi

    sleep "$DATA_HUB_POLL_INTERVAL"
done
