#!/bin/sh
# Fixture: one ready item, unclaimed, whose next step is pr: the fix is on its task branch and
# verify passed there. flow:next picks it, claims the pool worktree, writes the brief, runs the
# pr step and stops at the merge gate.
. "$(dirname "$0")/../_scaffold-common.sh"
scaffold task S "Greet strangers when no name is given" pr ready
set -e
github '{"issues": [], "pr": null}'
git -C .pool/wt-1 switch -q flow/local-task-1
(cd .pool/wt-1 && "$P/scripts/verify.sh" local:task/1 >/dev/null)
git -C .pool/wt-1 switch -q --detach main
