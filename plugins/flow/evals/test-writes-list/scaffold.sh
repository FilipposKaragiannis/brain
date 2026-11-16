#!/bin/sh
# The session starts in the item's pool worktree, as the unattended run starts a step, so the
# test writer can commit there; the graders read the task branch under .main.
. "$(dirname "$0")/../_scaffold-common.sh"
scaffold_in_worktree task S "Greet strangers" test implemented
