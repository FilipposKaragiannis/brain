#!/bin/sh
# local list [--all] [--kind KIND]: every open item (or every item with --all) as a JSON array,
# each with its rank and needs from the readiness rules (ready_rules in lib/flow.sh).
. "$(dirname "$0")/../../lib/flow.sh"
ready_rules
python3 -I "$FLOW_PLUGIN/adapters/local/_item.py" list "$(flow_home)" "$@"
