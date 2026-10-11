#!/bin/sh
# local close <id> [--comment TEXT]: close the item.
. "$(dirname "$0")/../../lib/flow.sh"
[ $# -ge 1 ] || die "usage: close <id> [--comment TEXT]" 2
id="$1"; text=""
[ "${2:-}" = "--comment" ] && text="$3"
python3 -I "$FLOW_PLUGIN/adapters/local/_item.py" close "$(flow_home)" "$id" "$text"
