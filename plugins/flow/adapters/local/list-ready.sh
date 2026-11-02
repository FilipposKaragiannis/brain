#!/bin/sh
# local list-ready [--kind KIND] [--pick NAME]: open items with no open blocker and no gate, as a
# JSON array; with --pick, only those the filter keeps (list.sh). A blocker in another tracker is
# read through that tracker's adapter.
. "$(dirname "$0")/../../lib/flow.sh"
"$FLOW_PLUGIN/adapters/local/list.sh" "$@" | "$FLOW_PLUGIN/scripts/filter-ready.sh"
