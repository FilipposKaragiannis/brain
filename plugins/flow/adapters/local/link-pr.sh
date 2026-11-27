#!/bin/sh
# local link-pr <id> <pr-url>: say the PR in a comment on the item. It writes no state: the flow
# records the PR and its host (lib/pull_request.sh).
. "$(dirname "$0")/../../lib/flow.sh"
[ $# -ge 2 ] || die "usage: link-pr <id> <pr-url>" 2
cached_python3 -I "$FLOW_PLUGIN/adapters/local/_item.py" comment "$(flow_home)" "$1" "PR: $2"
