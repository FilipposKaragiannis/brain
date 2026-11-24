#!/bin/sh
# filter-ready: reads a JSON array of items on stdin, joins each item's flow record onto it as its
# state (lib/state.sh items_join), and prints the ready ones: status open, gate none, no field the
# adapter lists under needs while no step has started, no open blocker the owner did not waive
# (gate.sh clear --option, lib/blockers.sh), a step left to run (not done, not split), not held
# behind an open item, for an item no step has started, no parent that waits at the decomposition
# gate (read with its flow record when the list leaves it out), and, for an epic's child that
# holds no claim, an epic branch on the remote for an epic above it, a parent that holds a claim
# or a base: line in its body (lib/base.sh refuses its claim without one; the epic branches are
# fetched when one is missing); lowest rank first, then the lowest item number (the oldest: GitHub
# and Jira list the newest first), else as listed. An item that lists its open blockers
# (open_blockers) is judged by that list; else each blocker is looked up through its own adapter's
# read operation, so a local item can wait on a GitHub issue and the other way round.
# A blocker that cannot be read still holds. The item a plan put this one behind (state.held_by)
# is looked up the same way but holds only while it reads open: a holder closed or not found frees
# the item, and next.sh or the health job lifts the tag. A hold keeps back only the steps after
# the profile's plan, so a plan sent back runs again. The ready: policy (lib/ready.sh, read and
# checked here whatever the caller exported) keeps back an item whose flow record another machine
# claimed, and an item the flow does not hold (no claim, no tracker step) whose tracker category is
# outside ready.categories or whose assignees ready.assignee does not allow
# (scripts/_ready_policy.py).
# With FLOW_READY_NOTES naming a file, each open item held back is appended to it as a JSON line,
# {"id", "worktree", "why"} (why: elsewhere, gate, status, assigned, needs, children, parent,
# epic-branch, split, done, blocked or held; an elsewhere one adds machine, a status one category,
# an assigned one assignees, a held one held_by and held_reason, a blocked one blocked_by, its open
# blockers, one that waits for an epic branch epic and branch), so next.sh can say why a pick
# found nothing.
. "$(dirname "$0")/../lib/flow.sh"
ready_policy
FLOW_MACHINE="$(flow_machine)"
export FLOW_MACHINE
items_join | cached_python3 -I "$FLOW_PLUGIN/scripts/_filter_ready.py" "$FLOW_PLUGIN" "$(flow_home)"
