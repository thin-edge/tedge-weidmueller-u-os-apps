#!/command/with-contenv sh
# Publishes system metrics of the controller as Cumulocity measurements on the
# main device and raises/clears alarms when thresholds are exceeded.
#
# Sources:
#  - CPU and memory: /proc/stat and /proc/meminfo. They are not namespaced by
#    Docker, so inside the container they report the whole controller.
#  - Disk: u-OS Administration API /system/disks (the controller's internal
#    storage), falling back to df on the add-on's data volume.
#  - Red status LEDs: u-OS Data Hub, provider u_os_ledc.
#  - Network: u-OS Administration API /network/state, published to the
#    inventory as "weidmueller_Network" whenever it changes.
set -u

INTERVAL="${METRICS_INTERVAL:-60}"
# Administration API data changes slowly; query it every N measurement cycles
SLOW_EVERY="${METRICS_SLOW_EVERY:-5}"
CPU_THRESHOLD="${METRICS_CPU_ALARM_THRESHOLD:-90}"
MEMORY_THRESHOLD="${METRICS_MEMORY_ALARM_THRESHOLD:-90}"
DISK_THRESHOLD="${METRICS_DISK_ALARM_THRESHOLD:-90}"
DISK_PATH="${METRICS_DISK_PATH:-/data/tedge}"

TOPIC="te/device/main//"
ALARM_TYPES="high_cpu_usage high_memory_usage high_disk_usage led_system_fault led_diagnostic_fault led_systembus_fault"

. /usr/local/lib/u-os-api.sh

log() {
    printf '%s\n' "[system-metrics] $*"
}

# Prints "<busy> <total>" CPU jiffies from the aggregate line of /proc/stat.
read_cpu_counters() {
    awk '/^cpu / {
        idle = $5 + $6
        total = 0
        for (i = 2; i <= NF; i++) total += $i
        print total - idle, total
        exit
    }' /proc/stat
}

memory_usage_percent() {
    awk '
        /^MemTotal:/ { total = $2 }
        /^MemAvailable:/ { avail = $2 }
        END { if (total > 0) printf "%.1f", (total - avail) * 100 / total }
    ' /proc/meminfo
}

# Usage of the controller's internal storage (all internal disks together).
api_disk_usage_percent() {
    uos_adm_get /system/disks u-os-adm.system.readonly | jq -r '
        [.items[]? | select(.storage_type == "Internal")] as $d
        | ($d | map(.total_size) | add // 0) as $total
        | ($d | map(.free_size) | add // 0) as $free
        | if $total > 0 then (($total - $free) * 1000 / $total | round) / 10 else empty end
    ' 2>/dev/null
}

df_disk_usage_percent() {
    df -P "$DISK_PATH" 2>/dev/null | awk 'NR == 2 { sub("%", "", $5); print $5 }'
}

network_payload() {
    uos_adm_get /network/state u-os-adm.network.readonly | jq -c '
        {
          interfaces: (.interfaces // {} | with_entries(.value = {
              type: .value.type,
              ipv4Enabled: (.value.ipv4.activated // false),
              ipv4Addresses: [.value.ipv4.addresses[]? | "\(.ip)/\(.prefix_length)"]
          })),
          defaultGateway: ([.routes[]? | select(.destination.ip == "0.0.0.0" and .destination.prefix_length == 0) | .gateway][0]),
          dnsServers: (.dns_resolver.servers // [])
        } | with_entries(select(.value != null))
    ' 2>/dev/null
}

# exceeds <value> <threshold> -> exit 0 if value >= threshold
exceeds() {
    awk -v v="$1" -v t="$2" 'BEGIN { exit !(v + 0 >= t + 0) }'
}

# Alarm state per type ("active"/"cleared"), so an alarm is only published
# when it changes. Initialised from the retained alarm messages: clearing an
# alarm that was never raised makes the c8y mapper log an "infinite loop"
# error, so only alarms that really exist get cleared.
init_alarm_states() {
    active=$(tedge mqtt sub "$TOPIC/a/+" --duration 2s 2>/dev/null \
        | awk 'NF > 1 { t = $1; gsub(/[][]/, "", t); n = split(t, p, "/"); print p[n] }')
    for type in $ALARM_TYPES; do
        if printf '%s\n' "$active" | grep -qx "$type"; then
            eval "alarm_$type=active"
        else
            eval "alarm_$type=cleared"
        fi
    done
}

# set_alarm <type> <active: true|false> <text> <severity>
set_alarm() {
    type="$1"; active="$2"; text="$3"; severity="$4"
    eval "state=\${alarm_$type:-cleared}"

    if [ "$active" = true ]; then
        [ "$state" = "active" ] && return 0
        payload=$(jq -n -c --arg text "$text" --arg severity "$severity" \
            '{text: $text, severity: $severity}')
        if tedge mqtt pub -r -q 1 "$TOPIC/a/$type" "$payload" >/dev/null 2>&1; then
            eval "alarm_$type=active"
            log "Raised alarm $type: $text"
        fi
    else
        [ "$state" = "cleared" ] && return 0
        # an empty retained message clears the alarm
        if tedge mqtt pub -r -q 1 "$TOPIC/a/$type" "" >/dev/null 2>&1; then
            eval "alarm_$type=cleared"
            log "Cleared alarm $type"
        fi
    fi
}

# update_alarm <type> <value> <threshold> <label>
update_alarm() {
    [ -n "$2" ] || return 0
    if exceeds "$2" "$3"; then
        set_alarm "$1" true "$4 usage is $2% (threshold $3%)" major
    else
        set_alarm "$1" false "" ""
    fi
}

# update_led_alarm <type> <led> <label> <severity>
# Any mode other than OFF (ON, blinking, ...) of the red LED counts as fault.
update_led_alarm() {
    mode=$(data_hub_get_variable u_os_ledc "$2.red.mode") || return 0
    if [ "$mode" != "OFF" ]; then
        set_alarm "$1" true "$3 LED of the controller is red ($mode)" "$4"
    else
        set_alarm "$1" false "" ""
    fi
}

publish_network() {
    payload=$(network_payload)
    [ -n "$payload" ] && [ "$payload" != "$last_network" ] || return 0
    if tedge mqtt pub -r -q 1 "$TOPIC/twin/weidmueller_Network" "$payload" >/dev/null 2>&1; then
        last_network="$payload"
        log "Published weidmueller_Network twin data"
    fi
}

if uos_configured; then
    use_api=true
else
    use_api=false
    log "u-OS API credentials not set in app settings: no LED alarms, no network info, disk from df"
fi

log "Publishing system metrics every ${INTERVAL}s"

# Wait for the MQTT broker (probe on a topic no mapper listens to), so the
# retained alarms can be read.
broker_wait=0
until tedge mqtt pub u-os-app/system-metrics/startup "" >/dev/null 2>&1 || [ "$broker_wait" -ge 30 ]; do
    broker_wait=$((broker_wait + 1))
    sleep 2
done
init_alarm_states

set -- $(read_cpu_counters)
prev_busy="${1:-0}"; prev_total="${2:-0}"
cycle=0
api_disk=""
last_network=""

while :; do
    sleep "$INTERVAL"

    set -- $(read_cpu_counters)
    busy="${1:-0}"; total="${2:-0}"
    cpu=$(awk -v b="$busy" -v pb="$prev_busy" -v t="$total" -v pt="$prev_total" \
        'BEGIN { dt = t - pt; if (dt > 0) printf "%.1f", (b - pb) * 100 / dt }')
    prev_busy="$busy"; prev_total="$total"

    memory=$(memory_usage_percent)

    if [ "$use_api" = true ] && [ $((cycle % SLOW_EVERY)) -eq 0 ]; then
        api_disk=$(api_disk_usage_percent)
        publish_network
    fi
    cycle=$((cycle + 1))
    disk="$api_disk"
    [ -n "$disk" ] || disk=$(df_disk_usage_percent)

    payload="{"
    sep=""
    [ -n "$cpu" ] && { payload="$payload$sep\"cpu\":{\"usage\":$cpu}"; sep=","; }
    [ -n "$memory" ] && { payload="$payload$sep\"memory\":{\"usage\":$memory}"; sep=","; }
    [ -n "$disk" ] && { payload="$payload$sep\"disk\":{\"usage\":$disk}"; sep=","; }
    payload="$payload}"

    if [ -n "$sep" ]; then
        tedge mqtt pub -q 1 "$TOPIC/m/system_metrics" "$payload" >/dev/null 2>&1 \
            || log "Could not publish measurement (MQTT broker not ready?)"
    fi

    update_alarm high_cpu_usage "$cpu" "$CPU_THRESHOLD" "CPU"
    update_alarm high_memory_usage "$memory" "$MEMORY_THRESHOLD" "Memory"
    update_alarm high_disk_usage "$disk" "$DISK_THRESHOLD" "Disk"

    if [ "$use_api" = true ]; then
        update_led_alarm led_system_fault system_condition "System" critical
        update_led_alarm led_diagnostic_fault diagnostic "Diagnostic" major
        update_led_alarm led_systembus_fault systembus_condition "System bus" major
    fi
done
