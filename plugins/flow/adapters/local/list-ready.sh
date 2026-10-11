#!/bin/sh
# local list-ready [--kind KIND]: open items with no open blocker and no gate, as a JSON array.
# A blocker in another tracker is read through that tracker's adapter.
. "$(dirname "$0")/../../lib/flow.sh"
"$FLOW_PLUGIN/adapters/local/list.sh" "$@" | "$FLOW_PLUGIN/scripts/filter-ready.sh"
