#!/bin/sh
# local read <id>: one item as JSON {id, kind, title, size, status, labels, blocked_by, rank, needs,
# state, url, body}; rank and needs from the readiness rules (ready_rules in lib/flow.sh).
. "$(dirname "$0")/../../lib/flow.sh"
ready_rules
[ $# -ge 1 ] || die "usage: read <id>" 2
python3 -I "$FLOW_PLUGIN/adapters/local/_item.py" read "$(flow_home)" "$1"
