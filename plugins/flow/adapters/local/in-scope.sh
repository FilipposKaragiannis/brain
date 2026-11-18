#!/bin/sh
# local in-scope <id>: exit 0 when the item is inside local.scope (or no scope is set), 1 when it
# is outside, 2 for a scope scope_check in lib/flow.sh refuses; on the item file's assignee,
# status, labels and kind, as list matches them.
. "$(dirname "$0")/../../lib/flow.sh"
[ $# -ge 1 ] || die "usage: in-scope <id>" 2
scope_filter local
python3 -I "$FLOW_PLUGIN/adapters/local/_item.py" in-scope "$(flow_home)" "$1"
