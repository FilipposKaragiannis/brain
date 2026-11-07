#!/bin/sh
# filter-ready: reads a JSON array of items on stdin and prints the ready ones: status open, gate
# none, no field the adapter lists under needs, no open blocker, a step left to run (not done, not
# split), not held behind an open item; lowest rank first, else as listed. An item that lists its
# open blockers (open_blockers) is judged by that list; else each blocker is looked up through its
# own adapter's read operation, so a local item can wait on a GitHub issue and the other way round.
# A blocker that cannot be read still holds. The item a plan put this one behind (state.held_by)
# is looked up the same way but holds only while it reads open: a holder closed or not found frees
# the item, and the health job clears the stale hold. With FLOW_READY_NOTES naming a file, each
# open item held back is appended to it as a JSON line, {"id", "worktree", "why"} (why: gate,
# needs, children, split, done, blocked or held; a held one adds held_by and held_reason), so
# next.sh can say why a pick found nothing.
. "$(dirname "$0")/../lib/flow.sh"
python3 -I "$FLOW_PLUGIN/scripts/_filter_ready.py" "$FLOW_PLUGIN"
