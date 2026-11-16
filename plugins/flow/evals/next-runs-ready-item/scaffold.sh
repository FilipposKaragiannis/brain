#!/bin/sh
# Fixture: one ready item, unclaimed, whose next step is pr: the fix is on its task branch and
# verify passed there. flow:next picks it, claims the pool worktree, writes the brief, runs the
# pr step and stops at the merge gate. The session starts in the pool worktree: a sandboxed Claude
# session cannot switch the branch of a worktree it did not start in, so a claim from the main
# checkout fails. The graders read the main checkout under .main.
. "$(dirname "$0")/../_scaffold-common.sh"
scaffold_in_worktree task S "Greet strangers when no name is given" pr ready
set -e
github '{"issues": [], "pr": null}'
git -C "$wt" switch -q flow/local-task-1
(cd "$wt" && "$P/scripts/verify.sh" local:task/1 >/dev/null)
git -C "$wt" switch -q --detach main
