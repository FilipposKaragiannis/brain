#!/bin/sh
# local list [--all] [--kind KIND]: every open item (or every item with --all) as a JSON array.
. "$(dirname "$0")/../../lib/flow.sh"
python3 -I "$FLOW_PLUGIN/adapters/local/_item.py" list "$(flow_home)" "$@"
