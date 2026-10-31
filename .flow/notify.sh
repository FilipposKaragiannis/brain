#!/bin/sh
# Written by flow:init. Calls the flow plugin notify script: notify.sh <gate> <item> <message>.
. "$(dirname "$0")/plugin.sh"
exec "$FLOW_PLUGIN/scripts/notify.sh" "$@"
