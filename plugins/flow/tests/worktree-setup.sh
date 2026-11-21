#!/bin/sh
# worktree-setup.sh: when a pool worktree is set up again, on the local adapter in throwaway repos
# with a bare origin. The steward records the commit a worktree's setup ran at; a claim runs
# worktree_setup again when a file worktree_setup_paths names differs between that commit and the
# worktree's HEAD, or when there is no record, and not otherwise; unset, no setup runs at a claim.
# A setup that fails at a claim is reported and the worktree is still handed out. The init
# template and the docs name the key.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

steward="$plugin/scripts/steward.sh"
lockfile_glob='**/package-lock.json'
marking_setup() { printf 'worktree_setup:\n  - basename "$PWD" >> %s/setup-runs.log%s\n' "$root" "$1" >> .flow/config.yaml; : > "$root/setup-runs.log"; }
watching_lockfiles() { printf 'worktree_setup_paths:\n  - "%s"\n' "$lockfile_glob" >> .flow/config.yaml; }
setup_runs() { grep -cxF "$1" "$root/setup-runs.log"; }
recorded_commit() { cat "$root/$1/.flow/setup-commit" 2>/dev/null; }
head_commit() { git -C "$root/$1" rev-parse HEAD; }
worktree_path() { (cd "$root/$1" && pwd -P); }

echo "worktree setup: with worktree_setup_paths unset a claim sets nothing up"
new_repo unset
marking_setup ""
unwatched="$(new_task "Fixtures")"
"$steward" claim "$unwatched" >/dev/null 2>&1
check "ClaimWithNoSetupPaths_RunsNoSetup: without the key a claim behaves as before" \
  '[ "$(setup_runs wt-1)" = 0 ]'
check "ClaimWithNoSetupPaths_WritesNoRecord: without the key the claim needs no record" \
  '[ ! -e "$root/wt-1/.flow/setup-commit" ]'

echo "worktree setup: a claim sets up a worktree whose watched files changed"
new_repo watched
marking_setup ""
watching_lockfiles
first="$(new_task "Ledger")"
"$steward" claim "$first" > "$work/first.out" 2> "$work/first.err"
check "ClaimOfAWorktreeWithNoSetupRecord_RunsTheSetup: a worktree never set up by the steward may hold any packages" \
  '[ "$(setup_runs wt-1)" = 1 ]'
check "ClaimOfAWorktreeWithNoSetupRecord_RecordsTheCommitItStandsAt: the next claim compares against the setup that just ran" \
  '[ -n "$(recorded_commit wt-1)" ] && [ "$(recorded_commit wt-1)" = "$(head_commit wt-1)" ]'
check "ClaimThatRunsTheSetup_PrintsOnlyTheWorktreePath: next.sh reads the path from what the claim prints" \
  '[ "$(cat "$work/first.out")" = "$(worktree_path wt-1)" ]'
"$steward" setup "$root/wt-2" >/dev/null 2>&1
check "SetupByHand_RecordsTheCommitTheSetupRanAt: a hand setup counts as the last setup too" \
  '[ -n "$(recorded_commit wt-2)" ] && [ "$(recorded_commit wt-2)" = "$(head_commit wt-2)" ]'
remote_commit main notes.txt
second="$(new_task "Notes")"
"$steward" claim "$second" >/dev/null 2>&1
check "ClaimWhereNoSetupPathChanged_SkipsTheSetup: a commit that leaves the lockfiles alone needs no reinstall" \
  '[ "$(recorded_commit wt-2)" != "$(head_commit wt-2)" ] && [ "$(setup_runs wt-2)" = 1 ]'
"$steward" setup "$root/wt-3" >/dev/null 2>&1
remote_commit main package-lock.json
third="$(new_task "Packages")"
"$steward" claim "$third" >/dev/null 2>&1
check "ClaimWhereASetupPathChanged_RunsTheSetupAgain: a changed lockfile means the installed packages are stale" \
  '[ "$(setup_runs wt-3)" = 2 ]'
check "ClaimWhereASetupPathChanged_RecordsTheNewCommit: the next claim compares against the setup that just ran" \
  '[ "$(recorded_commit wt-3)" = "$(head_commit wt-3)" ]'

echo "worktree setup: a setup that fails at a claim"
new_repo failing
marking_setup "; exit 1"
watching_lockfiles
failed="$(new_task "Broken install")"
"$steward" claim "$failed" > "$work/failed.out" 2> "$work/failed.err"; claim_code=$?
check "ClaimWhoseSetupFails_StillHandsOutTheWorktree: a failed setup at add hands the worktree out too" \
  '[ "$claim_code" -eq 0 ] && [ "$(cat "$work/failed.out")" = "$(worktree_path wt-1)" ] && [ -f "$root/wt-1/.flow/claim.json" ]'
check "ClaimWhoseSetupFails_ReportsTheFailedCommand: the owner learns the packages may be stale" \
  'grep -qF "flow: worktree_setup failed in $(worktree_path wt-1)" "$work/failed.err"'
check "ClaimWhoseSetupFails_LeavesNoRecord: the next claim must try the setup again" \
  '[ "$(setup_runs wt-1)" = 1 ] && [ ! -e "$root/wt-1/.flow/setup-commit" ]'

echo "worktree setup: the init template and the docs name the key"
git init -q "$work/fresh"
"$plugin/skills/init/scripts/init.sh" --root "$work/fresh" > "$work/init.out" 2>&1
check "InitTemplate_DocumentsWorktreeSetupPathsBesideWorktreeSetup: the owner finds the key where the setup commands are" \
  'grep -A2 "^worktree_setup:" "$work/fresh/.flow/config.yaml" | grep -q "^# worktree_setup_paths: "'
check "FlowDocsThatDescribeWorktreeSetup_NameWorktreeSetupPaths: whoever reads how the setup runs learns how to have it run again" \
  'for doc in $(grep -rl worktree_setup "$plugin/agents" "$plugin/codex-agents" "$plugin/skills" "$plugin/scripts/steward.sh"); do grep -q worktree_setup_paths "$doc" || { echo "$doc"; exit 1; }; done'

if [ "$fails" -eq 0 ]; then echo "worktree-setup: ok"; else echo "worktree-setup: $fails failed"; exit 1; fi
