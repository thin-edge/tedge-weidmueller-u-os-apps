#!/bin/sh
set -eu

# Invoked once per interval by the data-hub-measurements flow's
# input.process connector (see flow.toml) - NOT a long-running loop. stdout
# becomes the flow's output message (published to output.mqtt.topic
# unchanged, no transformation step needed); everything else (logging,
# writing the variables snapshot file) is a side effect of this script.

LOG_PREFIX="datahub-measurements"
# shellcheck source=../../lib/data-hub-client.sh
. /usr/local/lib/data-hub-client.sh

# The list of provider:key[:mode] entries to poll is NOT a u-OS setting/env
# var - it's a thin-edge configuration type (see tedge-configuration-plugin
# .toml, type data_hub_mapping), so a Cumulocity user can change it via
# Configuration Management ("Send configuration to device") without any
# access to u-OS App Settings. Comments (#...) and blank lines are ignored;
# remaining lines are joined with commas to feed the existing comma-based
# parsing below unchanged.
DATA_HUB_MAPPING_PATH="${DATA_HUB_MAPPING_PATH:-/data/tedge/data-hub-mapping.conf}"
DATA_HUB_VARIABLES=$(sed 's/#.*//' "$DATA_HUB_MAPPING_PATH" 2>/dev/null | tr -d ' \t' | grep -v '^$' | tr '\n' ',' | sed 's/,$//' || true)
# Snapshot of the FULL variable list (all keys + definitions, not just the
# ones configured above) for every provider referenced in DATA_HUB_VARIABLES,
# refreshed every cycle and exposed as a thin-edge/Cumulocity configuration
# type (see tedge-configuration-plugin.toml) so it can be fetched from
# Cumulocity's Configuration Management UI instead of docker exec. Valid
# JSON is valid YAML, so no separate YAML conversion is needed.
DATA_HUB_VARIABLES_SNAPSHOT_PATH="${DATA_HUB_VARIABLES_SNAPSHOT_PATH:-/data/tedge/data-hub-variables.yaml}"

is_number() {
    case "$1" in
        ''|*[!0-9.+-]*) return 1 ;;
        *) return 0 ;;
    esac
}

is_configured() {
    [ -n "$DATA_HUB_VARIABLES" ] \
        && [ -n "$DATA_HUB_CLIENT_ID" ] \
        && [ -n "$DATA_HUB_CLIENT_SECRET" ]
}

if ! is_configured; then
    exit 0
fi

# Each DATA_HUB_VARIABLES entry is provider:key[:mode], mode in {r,w,rw},
# defaulting to r. entry_provider/entry_key/entry_mode split one entry.
entry_provider() { printf '%s' "$1" | cut -s -d: -f1; }
entry_key()      { printf '%s' "$1" | cut -s -d: -f2; }
entry_mode() {
    mode=$(printf '%s' "$1" | cut -s -d: -f3)
    printf '%s' "${mode:-r}"
}
is_valid_mode() {
    case "$1" in r|w|rw) return 0 ;; *) return 1 ;; esac
}

# w/rw entries need a hub.variables.readwrite token (a readwrite token also
# satisfies reads, so one scope decision up front covers the whole config).
# w-only entries are otherwise not touched here - polling/publishing them as
# measurements makes no sense, and there is no write trigger wired up yet;
# data_hub_set_variable is available as a primitive for a future plan to use.
DATA_HUB_TOKEN_SCOPE="hub.variables.readonly"
write_count=0
old_ifs="$IFS"
IFS=','
for entry in $DATA_HUB_VARIABLES; do
    IFS="$old_ifs"
    if [ -n "$entry" ]; then
        case $(entry_mode "$entry") in
            w|rw) write_count=$((write_count + 1)) ;;
        esac
    fi
    IFS=','
done
IFS="$old_ifs"
if [ "$write_count" -gt 0 ]; then
    DATA_HUB_TOKEN_SCOPE="hub.variables.readwrite"
    log "Requesting hub.variables.readwrite token: $write_count write-capable ('w'/'rw') entries configured (write triggers not yet implemented - data_hub_set_variable is available as a primitive for a future plan)"
fi

build_measurement_payload() {
    payload=""
    old_ifs="$IFS"
    IFS=','
    for entry in $DATA_HUB_VARIABLES; do
        IFS="$old_ifs"
        [ -n "$entry" ] || continue

        provider=$(entry_provider "$entry")
        key=$(entry_key "$entry")
        mode=$(entry_mode "$entry")

        if [ -z "$provider" ] || [ -z "$key" ]; then
            log "Malformed entry '$entry' (need provider:key[:mode]), skipping"
            IFS=','
            continue
        fi
        if ! is_valid_mode "$mode"; then
            log "Entry '$entry' has invalid mode '$mode' (want r/w/rw), skipping"
            IFS=','
            continue
        fi
        if [ "$mode" = "w" ]; then
            IFS=','
            continue
        fi

        if ! value=$(data_hub_get_variable "$key" "$provider" 2>/dev/null); then
            log "Failed to fetch variable '$provider:$key', skipping this cycle"
            IFS=','
            continue
        fi

        if ! is_number "$value"; then
            log "Variable '$provider:$key' has a non-numeric value ('$value'), skipping"
            IFS=','
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

# Deduplicated, comma-separated list of providers referenced anywhere in
# DATA_HUB_VARIABLES (regardless of mode) - used to snapshot the full
# variable list per provider, not just the configured keys.
unique_providers() {
    seen=""
    old_ifs="$IFS"
    IFS=','
    for entry in $DATA_HUB_VARIABLES; do
        IFS="$old_ifs"
        provider=$(entry_provider "$entry")
        if [ -n "$provider" ]; then
            case ",$seen," in
                *",$provider,"*) ;;
                *) seen="${seen:+$seen,}$provider" ;;
            esac
        fi
        IFS=','
    done
    IFS="$old_ifs"
    printf '%s' "$seen"
}

# {"<provider>":[<data_hub_list_variables output, with definitions>], ...}
# for every unique provider - the FULL variable list each provider offers,
# not just the ones configured in DATA_HUB_VARIABLES.
build_variables_snapshot() {
    snapshot=""
    old_ifs="$IFS"
    IFS=','
    for provider in $(unique_providers); do
        IFS="$old_ifs"
        [ -n "$provider" ] || { IFS=','; continue; }

        if ! variables=$(data_hub_list_variables "$provider" "" true 2>/dev/null); then
            log "Failed to list variables for provider '$provider', skipping in snapshot"
            IFS=','
            continue
        fi

        fragment=$(printf '"%s":%s' "$(json_escape "$provider")" "$variables")
        if [ -n "$snapshot" ]; then
            snapshot="$snapshot,$fragment"
        else
            snapshot="$fragment"
        fi
        IFS=','
    done
    IFS="$old_ifs"
    printf '{%s}' "$snapshot"
}

write_variables_snapshot() {
    tmp_file="${DATA_HUB_VARIABLES_SNAPSHOT_PATH}.tmp"
    mkdir -p "$(dirname "$DATA_HUB_VARIABLES_SNAPSHOT_PATH")" 2>/dev/null || true

    if build_variables_snapshot | jq . > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$DATA_HUB_VARIABLES_SNAPSHOT_PATH"; then
        log "Updated Data Hub variables snapshot at $DATA_HUB_VARIABLES_SNAPSHOT_PATH"
    else
        rm -f "$tmp_file"
        log "Failed to write Data Hub variables snapshot to $DATA_HUB_VARIABLES_SNAPSHOT_PATH"
    fi
}

fields=$(build_measurement_payload)
if [ -n "$fields" ]; then
    echo "{$fields}"
else
    log "No numeric values retrieved this cycle, nothing published"
fi

write_variables_snapshot
