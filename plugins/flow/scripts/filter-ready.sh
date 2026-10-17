#!/bin/sh
# filter-ready: reads a JSON array of items on stdin and prints the ready ones: status open, gate
# none, no field the adapter lists under needs, no open blocker; lowest rank first, else as listed. A blocker is looked up through its own adapter's read operation, so a
# local item can wait on a GitHub issue and the other way round.
. "$(dirname "$0")/../lib/flow.sh"
python3 -I "$FLOW_PLUGIN/scripts/_filter_ready.py" "$FLOW_PLUGIN"
