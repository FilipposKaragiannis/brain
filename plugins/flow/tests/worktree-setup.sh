#!/bin/sh
# worktree-setup.sh: worktree_setup_paths and the setup record, on the local adapter in throwaway
# repos with a bare origin.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

steward="$plugin/scripts/steward.sh"
lockfile_glob='**/package-lock.json'
installing_setup() {
  printf 'worktree_setup:\n  - mkdir -p installed && git rev-parse HEAD > installed/from; cat package-lock.json > installed/lock 2>/dev/null || :%s\n' "$1" >> .flow/config.yaml
  printf 'installed/\n' >> .git/info/exclude
}
watching_lockfiles() { printf 'worktree_setup_paths:\n  - "%s"\n' "$lockfile_glob" >> .flow/config.yaml; }
installed_from() { cat "$root/$1/installed/from" 2>/dev/null; }
recorded_commit() { cat "$root/$1/.flow/setup-commit" 2>/dev/null; }
head_commit() { git -C "$root/$1" rev-parse HEAD; }
worktree_path() { (cd "$root/$1" && pwd -P); }
stale_claim() { python3 -c 'import json, sys; path = sys.argv[1] + "/.flow/claim.json"; claim = json.load(open(path)); claim["claimed_at"] = "2000-01-01T00:00:00Z"; json.dump(claim, open(path, "w"))' "$root/$1"; }

echo "worktree setup: with worktree_setup_paths unset a claim sets nothing up"
new_repo unset
installing_setup ""
unwatched="$(new_task "Fixtures")"
"$steward" claim "$unwatched" >/dev/null 2>&1
check "ClaimWithNoSetupPaths_InstallsNothing: without the key a claim behaves as before" \
  '[ ! -e "$root/wt-1/installed" ]'
check "ClaimWithNoSetupPaths_WritesNoRecord: without the key the claim needs no record" \
  '[ ! -e "$root/wt-1/.flow/setup-commit" ]'

echo "worktree setup: a claim sets up a worktree whose watched files changed"
new_repo watched
installing_setup ""
watching_lockfiles
first="$(new_task "Ledger")"
"$steward" claim "$first" > "$work/first.out" 2> "$work/first.err"
check "ClaimOfAWorktreeWithNoSetupRecord_InstallsAtTheCommitItStandsAt: a worktree never set up by the steward may hold any packages" \
  '[ -n "$(installed_from wt-1)" ] && [ "$(installed_from wt-1)" = "$(head_commit wt-1)" ]'
check "ClaimOfAWorktreeWithNoSetupRecord_RecordsTheCommitItStandsAt: the next claim compares against the setup that just ran" \
  '[ -n "$(recorded_commit wt-1)" ] && [ "$(recorded_commit wt-1)" = "$(head_commit wt-1)" ]'
check "ClaimThatRunsTheSetup_PrintsOnlyTheWorktreePath: next.sh reads the path from what the claim prints" \
  '[ "$(cat "$work/first.out")" = "$(worktree_path wt-1)" ]'
"$steward" setup "$root/wt-2" >/dev/null 2>&1
check "SetupByHand_RecordsTheCommitTheSetupRanAt: a hand setup counts as the last setup too" \
  '[ -n "$(recorded_commit wt-2)" ] && [ "$(recorded_commit wt-2)" = "$(installed_from wt-2)" ]'
remote_commit main notes.txt
second="$(new_task "Notes")"
"$steward" claim "$second" >/dev/null 2>&1
check "ClaimWhereNoSetupPathChanged_KeepsTheEarlierInstall: a commit that leaves the lockfiles alone needs no reinstall" \
  '[ "$(installed_from wt-2)" = "$(recorded_commit wt-2)" ] && [ "$(installed_from wt-2)" != "$(head_commit wt-2)" ]'
"$steward" setup "$root/wt-3" >/dev/null 2>&1
remote_commit main package-lock.json
third="$(new_task "Packages")"
"$steward" claim "$third" >/dev/null 2>&1
check "ClaimWhereASetupPathChanged_InstallsTheNewLockfile: a changed lockfile means the installed packages are stale" \
  '[ -s "$root/wt-3/installed/lock" ] && cmp -s "$root/wt-3/installed/lock" "$root/wt-3/package-lock.json"'
check "ClaimWhereASetupPathChanged_RecordsTheNewCommit: the next claim compares against the setup that just ran" \
  '[ "$(recorded_commit wt-3)" = "$(head_commit wt-3)" ]'

echo "worktree setup: a setup that does not finish leaves no record"
new_repo interrupted
installing_setup "; [ ! -f $root/setup-breaks ] || { rm -rf installed; exit 1; }; [ ! -f $root/setup-commits ] || git commit -q --allow-empty -m during-setup"
watching_lockfiles
"$steward" setup "$root/wt-1" >/dev/null 2>&1
touch "$root/setup-breaks"; "$steward" setup "$root/wt-1" >/dev/null 2>&1; rm -f "$root/setup-breaks"
broken="$(new_task "Broken reinstall")"
"$steward" claim "$broken" >/dev/null 2>&1
check "ClaimAfterASetupThatFailedAtTheRecordedCommit_InstallsAgain: a failed install may have removed what the earlier one put there" \
  '[ -n "$(installed_from wt-1)" ] && [ "$(installed_from wt-1)" = "$(head_commit wt-1)" ]'
touch "$root/setup-commits"; "$steward" setup "$root/wt-2" >/dev/null 2>&1; rm -f "$root/setup-commits"
check "SetupDuringWhichTheWorktreeMoves_RecordsTheCommitItStartedAt: the setup installed from that commit's files" \
  '[ -n "$(recorded_commit wt-2)" ] && [ "$(recorded_commit wt-2)" = "$(installed_from wt-2)" ] && [ "$(recorded_commit wt-2)" != "$(head_commit wt-2)" ]'

echo "worktree setup: a lockfile under a folder with a name outside ASCII"
new_repo unicode
installing_setup ""
watching_lockfiles
"$steward" setup "$root/wt-1" >/dev/null 2>&1
lock_folder='café'
git -C "$root/other" fetch -q origin && git -C "$root/other" checkout -q -B main origin/main
mkdir -p "$root/other/$lock_folder" && printf 'lock\n' > "$root/other/$lock_folder/package-lock.json"
git -C "$root/other" add -- "$lock_folder" && git -C "$root/other" commit -qm lock && git -C "$root/other" push -q origin main
accented="$(new_task "Accented lockfile")"
"$steward" claim "$accented" >/dev/null 2>&1
check "ClaimWhereALockfileUnderANonAsciiFolderChanged_InstallsAgain: git quotes such a path unless asked not to, and a quoted path matches no glob" \
  '[ -n "$(installed_from wt-1)" ] && [ "$(installed_from wt-1)" = "$(head_commit wt-1)" ]'
mkdir -p "$root/wt-2/.flow" && printf '%040d\n' 0 > "$root/wt-2/.flow/setup-commit"
forgotten="$(new_task "Forgotten record")"
"$steward" claim "$forgotten" >/dev/null 2>&1
check "ClaimWhoseRecordedCommitIsUnknown_InstallsAgain: nothing can be compared with a commit git does not have" \
  '[ -n "$(installed_from wt-2)" ] && [ "$(installed_from wt-2)" = "$(head_commit wt-2)" ]'

echo "worktree setup: a setup that fails at a claim"
new_repo failing
installing_setup "; exit 1"
watching_lockfiles
failed="$(new_task "Broken install")"
"$steward" claim "$failed" > "$work/failed.out" 2> "$work/failed.err"; claim_code=$?
check "ClaimWhoseSetupFails_StillHandsOutTheWorktree: a failed setup at add hands the worktree out too" \
  '[ "$claim_code" -eq 0 ] && [ "$(cat "$work/failed.out")" = "$(worktree_path wt-1)" ] && [ -f "$root/wt-1/.flow/claim.json" ]'
check "ClaimWhoseSetupFails_ReportsTheFailedCommand: the owner learns the packages may be stale" \
  'grep -qF "flow: worktree_setup failed in $(worktree_path wt-1)" "$work/failed.err"'
check "ClaimWhoseSetupFails_LeavesNoRecord: the next claim must try the setup again" \
  '[ -n "$(installed_from wt-1)" ] && [ ! -e "$root/wt-1/.flow/setup-commit" ]'

echo "worktree setup: while a claim's setup runs"
new_repo busy
setup_wait_seconds=120
installing_setup "; touch '$root/setup-started'; remaining=$setup_wait_seconds; while [ ! -f '$root/setup-may-end' ]; do [ \$remaining -gt 0 ] || exit 1; sleep 1; remaining=\$((remaining - 1)); done; echo setup-ended >> '$root/order.log'"
watching_lockfiles
slow="$(new_task "Slow install")"
"$steward" claim "$slow" > "$work/slow.out" 2>&1 & claim_pid=$!
while [ ! -f "$root/setup-started" ] && kill -0 "$claim_pid" 2>/dev/null; do sleep 1; done
{ "$steward" claim "$slow" 2> "$work/again.err" | sed 's/^/claim /' >> "$root/order.log"; } & again_pid=$!
{ sh -c '. "$FLOW_PLUGIN/lib/flow.sh" && . "$FLOW_PLUGIN/lib/base.sh" && claim_at_base "$1" "{}"' claim-at-base "$slow" 2> "$work/next.err" | sed 's/^/next /' >> "$root/order.log"; } & next_pid=$!
while ! grep -q "waiting for the worktree_setup" "$work/again.err" 2>/dev/null && kill -0 "$again_pid" 2>/dev/null; do sleep 1; done
while ! grep -q "waiting for the worktree_setup" "$work/next.err" 2>/dev/null && kill -0 "$next_pid" 2>/dev/null; do sleep 1; done
stale_claim wt-1
"$steward" health > "$work/health-during.out" 2>&1
check "HealthWhileTheSetupAtAClaimRuns_KeepsTheClaim: an install longer than the grace is work, not an empty claim" \
  '[ -f "$root/wt-1/.flow/claim.json" ] && ! grep -q "released the empty claim" "$work/health-during.out"'
touch "$root/setup-may-end"; wait "$claim_pid" "$again_pid" "$next_pid"
printed_after_setup() { awk -v who="$1" '$1 == "setup-ended" { ended = NR } $1 == who { printed = NR } END { exit !(ended && printed > ended) }' "$root/order.log"; }
check "ClaimOfAnItemWhoseSetupRuns_PrintsThePathAfterTheSetup: work must not start on half-installed packages" \
  'printed_after_setup claim'
check "ClaimAtBaseOfAnItemWhoseSetupRuns_PrintsThePathAfterTheSetup: next.sh starts the step only on a set-up worktree" \
  'printed_after_setup next'
stale_claim wt-1
"$steward" health > "$work/health-after.out" 2>&1
check "HealthAfterTheSetupAtAClaimEnded_ReleasesTheEmptyClaim: the mark of a running setup goes when the setup ends" \
  '[ ! -f "$root/wt-1/.flow/claim.json" ] && grep -q "released the empty claim" "$work/health-after.out"'

echo "worktree setup: the init template and the docs name the key"
git init -q "$work/fresh"
"$plugin/skills/init/scripts/init.sh" --root "$work/fresh" > "$work/init.out" 2>&1
check "InitTemplate_DocumentsWorktreeSetupPathsBesideWorktreeSetup: the owner finds the key where the setup commands are" \
  'grep -A2 "^worktree_setup:" "$work/fresh/.flow/config.yaml" | grep -q "^# worktree_setup_paths: "'
check "FlowDocsThatDescribeWorktreeSetup_NameWorktreeSetupPaths: whoever reads how the setup runs learns how to have it run again" \
  'for doc in $(grep -rl worktree_setup "$plugin/agents" "$plugin/codex-agents" "$plugin/skills" "$plugin/scripts/steward.sh"); do grep -q worktree_setup_paths "$doc" || { echo "$doc"; exit 1; }; done'

if [ "$fails" -eq 0 ]; then echo "worktree-setup: ok"; else echo "worktree-setup: $fails failed"; exit 1; fi
