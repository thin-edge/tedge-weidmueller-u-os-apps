#!/command/with-contenv sh
# The shebang loads the container environment (DATA_HUB_*, C8Y_*). It must
# live here: an s6-rc oneshot "up" file is parsed by execlineb as a single
# command line, so a shebang placed in "up" is ignored.
set -eu

log() {
    printf '%s\n' "[startup-inventory] $*"
}

json_escape() {
    printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

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

. /usr/local/lib/u-os-api.sh

DATA_HUB_PROVIDER="${DATA_HUB_PROVIDER:-u_os_adm}"

nameplate() {
    data_hub_get_variable "$DATA_HUB_PROVIDER" "digital_nameplate.$1"
}

detect_hardware_model() {
    nameplate manufacturer_product_type && return 0
    read_first_non_empty_file \
        /sys/firmware/devicetree/base/model \
        /proc/device-tree/model \
        /sys/class/dmi/id/product_name \
        /sys/devices/virtual/dmi/id/product_name \
        || true
}

detect_hardware_revision() {
    nameplate hardware_version && return 0
    read_first_non_empty_file \
        /sys/class/dmi/id/product_version \
        /sys/devices/virtual/dmi/id/product_version \
        /sys/class/dmi/id/board_version \
        /sys/devices/virtual/dmi/id/board_version \
        || true
}

detect_hardware_serial() {
    nameplate serial_number && return 0
    read_first_non_empty_file \
        /sys/firmware/devicetree/base/serial-number \
        /proc/device-tree/serial-number \
        /sys/class/dmi/id/product_serial \
        /sys/devices/virtual/dmi/id/product_serial \
        /etc/machine-id \
        || true
}

# Firmware of the controller from the u-OS Administration API (/system/info).
# Fallbacks: Data Hub nameplate for the version, "u-OS" for the name.
# /etc/os-release must not be used: inside this container it describes the
# container's (Alpine) base image, not the controller's OS.
system_info_field() {
    uos_adm_get /system/info u-os-adm.system.readonly \
        | jq -r "$1 // empty" 2>/dev/null | grep .
}

detect_firmware_name() {
    system_info_field .firmware.name && return 0
    printf '%s' "u-OS"
}

detect_firmware_version() {
    system_info_field .firmware.version && return 0
    nameplate software_version
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

    if ! data_hub_configured; then
        log "Data Hub: DATA_HUB_CLIENT_ID/DATA_HUB_CLIENT_SECRET not set in app settings, using fallbacks"
    fi

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
            # "url" is always sent (empty if unknown): the Cumulocity device
            # certification checks that all three properties are present.
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

ensure_default_config_type() {
    plugin_file="/etc/tedge/plugins/tedge-configuration-plugin.toml"
    max_attempts=120
    attempt=1

    while [ "$attempt" -le "$max_attempts" ]; do
        if [ ! -f "$plugin_file" ]; then
            attempt=$((attempt + 1))
            sleep 1
            continue
        fi

        if grep -q "type = 'default'" "$plugin_file"; then
            log "Configuration plugin already contains default config type"
            return 0
        fi

        tmp_file="${plugin_file}.tmp"
        awk '
            {
                print $0
                if ($0 ~ /path = '\''\/etc\/tedge\/tedge\.toml'\''/ && inserted == 0) {
                    print "    { path = '\''/etc/tedge/tedge.toml'\'', type = '\''default'\'', user = '\''tedge'\'', group = '\''tedge'\'', mode = 0o444 },"
                    inserted = 1
                }
            }
        ' "$plugin_file" > "$tmp_file"

        if [ -s "$tmp_file" ]; then
            mv "$tmp_file" "$plugin_file"
            log "Added default config type to $plugin_file"
            return 0
        fi

        rm -f "$tmp_file"
        attempt=$((attempt + 1))
        sleep 1
    done

    log "Failed to patch default config type in $plugin_file"
    return 0
}

# Additional nameplate data (manufacturer, order code, ...) as a custom
# inventory fragment. Not required for certification, makes the device easier
# to identify in Cumulocity.
publish_nameplate() {
    data_hub_configured || return 0

    payload=$(jq -n -c \
        --arg manufacturer "$(nameplate manufacturer_name || true)" \
        --arg productType "$(nameplate manufacturer_product_type || true)" \
        --arg orderCode "$(nameplate order_code_of_manufacturer || true)" \
        --arg serialNumber "$(nameplate serial_number || true)" \
        --arg hardwareVersion "$(nameplate hardware_version || true)" \
        --arg softwareVersion "$(nameplate software_version || true)" \
        --arg yearOfConstruction "$(nameplate year_of_construction || true)" \
        --arg street "$(nameplate address_information.street || true)" \
        --arg zipcode "$(nameplate address_information.zipcode || true)" \
        --arg city "$(nameplate address_information.city_town || true)" \
        --arg country "$(nameplate address_information.national_code || true)" \
        '{manufacturer: $manufacturer, productType: $productType,
          orderCode: $orderCode, serialNumber: $serialNumber,
          hardwareVersion: $hardwareVersion, softwareVersion: $softwareVersion,
          yearOfConstruction: $yearOfConstruction,
          manufacturerAddress: ({street: $street, zipcode: $zipcode,
                                 city: $city, country: $country}
                                | with_entries(select(.value != "")))}
         | with_entries(select(.value != "" and .value != {}))')

    if [ "$payload" = "{}" ] || [ -z "$payload" ]; then
        log "Data Hub: no nameplate data available"
        return 0
    fi

    attempt=1
    while [ "$attempt" -le 15 ]; do
        if tedge mqtt pub -r te/device/main///twin/weidmueller_Nameplate "$payload" >/dev/null 2>&1; then
            log "Published weidmueller_Nameplate twin data"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    log "Failed to publish weidmueller_Nameplate"
    return 0
}

ensure_default_config_type
publish_if_configured
publish_nameplate
