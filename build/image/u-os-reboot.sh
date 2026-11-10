#!/bin/sh
# Runs via sudo from tedge-agent; the container environment (DATA_HUB_*)
# is loaded by u-os-api.sh.
# Reboot command for thin-edge.io (system.toml [system] reboot), used by the
# Cumulocity "Restart" operation (c8y_Restart).
#
# Reboots the whole u-OS controller through the Administration API
# (POST /system:reboot, scope u-os-adm.system.readwrite). The add-on container
# restarts with the controller, and tedge-agent then reports the operation
# as successful.
#
# Fallback when the API is not usable (no credentials or scope): restart only
# this container, as the base image did before.
set -u

. /usr/local/lib/u-os-api.sh

log() {
    printf '%s\n' "[u-os-reboot] $*"
}

if uos_configured && uos_request POST "$UOS_ADM_API/system:reboot" u-os-adm.system.readwrite >/dev/null; then
    log "Controller reboot requested via u-OS Administration API"
    exit 0
fi

log "Controller reboot via u-OS API failed (scope u-os-adm.system.readwrite missing?), restarting the container only"
exec /usr/bin/tedgectl restart_device
