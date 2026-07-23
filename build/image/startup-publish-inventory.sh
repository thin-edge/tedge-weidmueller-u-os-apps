#!/bin/sh
set -eu

LOG_PREFIX="startup-inventory"
# shellcheck source=lib/data-hub-client.sh
. /usr/local/lib/data-hub-client.sh

read_first_non_empty_file() {
    for candidate in "$@"; do
        if [ -f "$candidate" ]; then
            value=$(tr -d '\000' < "$candidate" | tr -d '\r' | sed -n '1p')
            if [ -n "$value" ]; then
                printf '%s' "$value"
                return 0
            fi
        fi
    done
    return 1
}

DATA_HUB_PROVIDER="${DATA_HUB_PROVIDER:-u_os_adm}"

# u-OS Data Hub reports the values that were physically flashed onto the
# device, unlike /sys or /proc inside this container, which only reflect the
# container's own (Alpine) view and can't see the host's hardware/firmware.
detect_hardware_model() {
    data_hub_get_variable "digital_nameplate.manufacturer_product_type" "$DATA_HUB_PROVIDER" && return 0
    read_first_non_empty_file \
        /sys/firmware/devicetree/base/model \
        /proc/device-tree/model \
        /sys/class/dmi/id/product_name \
        /sys/devices/virtual/dmi/id/product_name \
        || true
}

detect_hardware_revision() {
    data_hub_get_variable "digital_nameplate.hardware_version" "$DATA_HUB_PROVIDER" && return 0
    read_first_non_empty_file \
        /sys/class/dmi/id/product_version \
        /sys/devices/virtual/dmi/id/product_version \
        /sys/class/dmi/id/board_version \
        /sys/devices/virtual/dmi/id/board_version \
        || true
}

detect_hardware_serial() {
    data_hub_get_variable "digital_nameplate.serial_number" "$DATA_HUB_PROVIDER" && return 0
    read_first_non_empty_file \
        /sys/firmware/devicetree/base/serial-number \
        /proc/device-tree/serial-number \
        /sys/class/dmi/id/product_serial \
        /sys/devices/virtual/dmi/id/product_serial \
        /etc/machine-id \
        || true
}

detect_firmware_name() {
    if [ -r /etc/os-release ]; then
        name=$(sed -n 's/^NAME=//p' /etc/os-release | sed 's/^"//; s/"$//')
        if [ -n "$name" ]; then
            printf '%s' "$name"
            return 0
        fi
    fi
    return 1
}

detect_firmware_version() {
    data_hub_get_variable "digital_nameplate.software_version" "$DATA_HUB_PROVIDER" && return 0
    if [ -r /etc/os-release ]; then
        version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | sed 's/^"//; s/"$//')
        if [ -n "$version" ]; then
            printf '%s' "$version"
            return 0
        fi
    fi
    return 1
}

build_hardware_payload() {
    payload=$(printf '{"model":"%s"' "$(json_escape "$hw_model")")

    if [ -n "$hw_revision" ]; then
        payload="$payload$(printf ',"revision":"%s"' "$(json_escape "$hw_revision")")"
    fi

    if [ -n "$hw_serial" ]; then
        payload="$payload$(printf ',"serialNumber":"%s"' "$(json_escape "$hw_serial")")"
    fi

    payload="$payload}"
    printf '%s' "$payload"
}

publish_if_configured() {
    hw_model="${C8Y_HARDWARE_MODEL:-}"
    hw_revision="${C8Y_HARDWARE_REVISION:-}"
    hw_serial="${C8Y_HARDWARE_SERIAL_NUMBER:-}"

    fw_name="${C8Y_FIRMWARE_NAME:-}"
    fw_version="${C8Y_FIRMWARE_VERSION:-}"
    fw_url="${C8Y_FIRMWARE_URL:-}"

    [ -n "$hw_model" ] || hw_model="$(detect_hardware_model)"
    [ -n "$hw_revision" ] || hw_revision="$(detect_hardware_revision)"
    [ -n "$hw_serial" ] || hw_serial="$(detect_hardware_serial)"

    [ -n "$fw_name" ] || fw_name="$(detect_firmware_name || true)"
    [ -n "$fw_version" ] || fw_version="$(detect_firmware_version || true)"

    publish_hardware=false
    if [ -n "$hw_model" ]; then
        publish_hardware=true
    fi

    publish_firmware=false
    if [ -n "$fw_name" ] && [ -n "$fw_version" ]; then
        publish_firmware=true
    fi

    if [ "$publish_hardware" = false ] && [ "$publish_firmware" = false ]; then
        log "No hardware/firmware inventory env vars configured, skipping publish"
        return 0
    fi

    max_attempts=15
    attempt=1
    while [ "$attempt" -le "$max_attempts" ]; do
        if [ "$publish_hardware" = true ]; then
            hardware_payload="$(build_hardware_payload)"

            if ! tedge mqtt pub -r te/device/main///twin/c8y_Hardware "$hardware_payload" >/dev/null 2>&1; then
                log "Attempt $attempt/$max_attempts: waiting for MQTT to publish c8y_Hardware"
                attempt=$((attempt + 1))
                sleep 2
                continue
            fi
        fi

        if [ "$publish_firmware" = true ]; then
            firmware_payload=$(printf '{"name":"%s","version":"%s","url":"%s"}' \
                "$(json_escape "$fw_name")" \
                "$(json_escape "$fw_version")" \
                "$(json_escape "$fw_url")")

            if ! tedge mqtt pub -r te/device/main///twin/firmware "$firmware_payload" >/dev/null 2>&1; then
                log "Attempt $attempt/$max_attempts: waiting for MQTT to publish firmware twin"
                attempt=$((attempt + 1))
                sleep 2
                continue
            fi
        fi

        log "Published c8y_Hardware/c8y_Firmware twin data"
        return 0
    done

    log "Failed to publish inventory fragments after $max_attempts attempts"
    return 0
}

# ensure_config_type <type> <path>
# Idempotently adds a { path, type, user, group, mode } entry to the
# tedge-configuration-plugin.toml config-management file, if a config type
# with that name isn't already present. Waits for the file to exist first,
# since it's (re)written by thin-edge itself at startup and may not exist
# yet - or may have just been reset to its defaults - when this runs.
ensure_config_type() {
    config_type="$1"
    file_path="$2"
    plugin_file="/etc/tedge/plugins/tedge-configuration-plugin.toml"
    max_attempts=120
    attempt=1

    while [ "$attempt" -le "$max_attempts" ]; do
        if [ ! -f "$plugin_file" ]; then
            attempt=$((attempt + 1))
            sleep 1
            continue
        fi

        if grep -q "type = '$config_type'" "$plugin_file"; then
            log "Configuration plugin already contains $config_type config type"
            return 0
        fi

        tmp_file="${plugin_file}.tmp"
        awk -v type="$config_type" -v path="$file_path" '
            {
                print $0
                if ($0 ~ /path = '\''\/etc\/tedge\/tedge\.toml'\''/ && inserted == 0) {
                    print "    { path = '\''" path "'\'', type = '\''" type "'\'', user = '\''tedge'\'', group = '\''tedge'\'', mode = 0o444 },"
                    inserted = 1
                }
            }
        ' "$plugin_file" > "$tmp_file"

        if [ -s "$tmp_file" ]; then
            mv "$tmp_file" "$plugin_file"
            log "Added $config_type config type to $plugin_file"
            return 0
        fi

        rm -f "$tmp_file"
        attempt=$((attempt + 1))
        sleep 1
    done

    log "Failed to patch $config_type config type in $plugin_file"
    return 0
}

ensure_config_type "default" "/etc/tedge/tedge.toml"
ensure_config_type "data_hub_variables" "/data/tedge/data-hub-variables.yaml"
ensure_config_type "data_hub_mapping" "/data/tedge/data-hub-mapping.conf"
publish_if_configured
