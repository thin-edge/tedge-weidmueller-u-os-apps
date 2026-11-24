#!/bin/sh
set -eu

LOG_PREFIX="datahub-list-variables"
# shellcheck source=lib/data-hub-client.sh
. /usr/local/lib/data-hub-client.sh

if [ $# -lt 1 ] || [ $# -gt 3 ]; then
    echo "usage: $0 <provider> [prefixes] [definition:true|false]" >&2
    echo "example: $0 plc1 '' true" >&2
    exit 2
fi

data_hub_list_variables "$1" "${2:-}" "${3:-false}"
