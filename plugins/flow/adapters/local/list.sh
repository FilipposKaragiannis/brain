#!/bin/sh
# local list [--all] [--kind KIND] [--pick NAME]: every open item (or every item with --all) as a
# JSON array, each with its rank and needs from the readiness rules (ready_rules in lib/flow.sh).
# --pick keeps the items the filter pick.<name> matches (pick_filter in lib/flow.sh), on the item
# file's assignee, status, labels and kind.
. "$(dirname "$0")/../../lib/flow.sh"
ready_rules
pick_filter local "$@" || { echo '[]'; exit 0; }
python3 -I "$FLOW_PLUGIN/adapters/local/_item.py" list "$(flow_home)" "$@"
