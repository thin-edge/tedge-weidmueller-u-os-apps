#!/bin/sh
set -eu

log() {
    printf '%s\n' "[startup-inventory] $*"
}

json_escape() {
    printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

publish_if_configured() {
    hw_model="${C8Y_HARDWARE_MODEL:-}"
    hw_revision="${C8Y_HARDWARE_REVISION:-}"
    hw_serial="${C8Y_HARDWARE_SERIAL_NUMBER:-}"

    fw_name="${C8Y_FIRMWARE_NAME:-}"
    fw_version="${C8Y_FIRMWARE_VERSION:-}"
    fw_url="${C8Y_FIRMWARE_URL:-}"

    publish_hardware=false
    if [ -n "$hw_model" ] && [ -n "$hw_revision" ] && [ -n "$hw_serial" ]; then
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

    max_attempts=90
    attempt=1
    while [ "$attempt" -le "$max_attempts" ]; do
        if [ "$publish_hardware" = true ]; then
            hardware_payload=$(printf '{"model":"%s","revision":"%s","serialNumber":"%s"}' \
                "$(json_escape "$hw_model")" \
                "$(json_escape "$hw_revision")" \
                "$(json_escape "$hw_serial")")

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
    return 1
}

publish_if_configured &

exec "$@"