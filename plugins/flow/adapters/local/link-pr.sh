#!/bin/sh
# local link-pr <id> <pr-url>: record the PR on the item.
. "$(dirname "$0")/../../lib/flow.sh"
[ $# -ge 2 ] || die "usage: link-pr <id> <pr-url>" 2
python3 -I "$FLOW_PLUGIN/adapters/local/_item.py" write-state "$(flow_home)" "$1" "pr=$2"
python3 -I "$FLOW_PLUGIN/adapters/local/_item.py" comment "$(flow_home)" "$1" "PR: $2"
