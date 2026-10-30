#!/bin/sh
# local write-state <id> key=value...: set state fields (step, profile, size, worktree, attempts,
# gate, last_event, pr, touches, and the last gate's answered, asked, answer, answered_at). Lists
# are comma-separated.
. "$(dirname "$0")/../../lib/flow.sh"
[ $# -ge 2 ] || die "usage: write-state <id> key=value..." 2
python3 -I "$FLOW_PLUGIN/adapters/local/_item.py" write-state "$(flow_home)" "$@"
