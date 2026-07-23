#!/bin/sh
set -eu

LOG_PREFIX="datahub-set-variable"
# shellcheck source=lib/data-hub-client.sh
. /usr/local/lib/data-hub-client.sh

DATA_HUB_TOKEN_SCOPE="hub.variables.readwrite"

if [ $# -ne 3 ]; then
    echo "usage: $0 <provider> <key> <json-value>" >&2
    echo "example: $0 io_link_1 setpoint 42" >&2
    exit 2
fi

data_hub_set_variable "$1" "$2" "$3"
