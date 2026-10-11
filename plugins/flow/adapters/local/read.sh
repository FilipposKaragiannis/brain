#!/bin/sh
# local read <id>: one item as JSON {id, kind, title, size, status, labels, blocked_by, state, url, body}.
. "$(dirname "$0")/../../lib/flow.sh"
[ $# -ge 1 ] || die "usage: read <id>" 2
python3 -I "$FLOW_PLUGIN/adapters/local/_item.py" read "$(flow_home)" "$1"
