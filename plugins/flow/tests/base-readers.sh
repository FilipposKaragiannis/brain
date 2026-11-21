#!/bin/sh
# base-readers.sh: an item's recorded base is read by every reader, on the local adapter in
# throwaway repos with a bare origin. A child of an epic is claimed from the epic branch and records
# it in claim.json and state.base; health, the merge before verify, verify.sh, the brief, the JSON,
# the hold-release note, the board and init --check all read the recorded base, and a claim.json
# base that is not a safe name never reaches the board or init.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
# pool_entry_field <board-json> <item> <field>: the field of the item's pool entry, as JSON.
pool_entry_field() { python3 -c 'import json,sys; entries=[pool_entry for pool_entry in json.load(open(sys.argv[1]))["pool"] if pool_entry.get("item")==sys.argv[2]]; print(json.dumps(entries[0][sys.argv[3]]) if entries else "no pool entry")' "$@"; }

echo "base: a child of an epic is claimed from the epic branch"
new_repo epic
epic="$("$local_adapter/create.sh" epic "Physics" --size L --body x)"
epic_branch="$(epic_of "$epic")"
remote_branch "$epic_branch"; remote_commit "$epic_branch" epic-start.txt
child="$(new_task "Ball spin" "$epic")"
"$plugin/scripts/next.sh" "$child" --json > "$work/child.json" 2>/dev/null
worktree="$("$plugin/scripts/steward.sh" find "$child")"; task_branch="flow/$(slug "$child")"; git fetch -q origin
check "EpicChild_BranchDescendsFromTheEpicBranch: a child of an epic whose epic/<n> is on the remote starts from it, so the epic's own commit is on the branch right after the claim" \
  'git -C "$worktree" merge-base --is-ancestor "origin/$epic_branch" "$task_branch"'
check "EpicChild_ClaimJsonRecordsTheEpicBranch: claim.json carries the base every reader in the worktree takes" \
  '[ "$(claim_base "$child")" = "$epic_branch" ]'
check "EpicChild_ItemStateRecordsTheEpicBranch: state.base carries the base for a step that has no worktree" \
  '[ "$(state "$child" base)" = "$epic_branch" ]'
check "EpicChild_EventsLogNamesTheBaseOfTheClaim: the claim says which base it started from" \
  'grep "	$child	claim	" .flow/events.log | grep -qF "$epic_branch"'
check "EpicChild_JsonBaseIsTheEpicBranch: next.sh --json hands the runner the recorded base, not the config base" \
  '[ "$(json_value base < "$work/child.json")" = "$epic_branch" ]'
check "EpicChild_BriefNamesTheEpicBranchAsBase: the brief tells the agent the recorded base" \
  'grep -qF "\`$epic_branch\`" "$(json_value brief < "$work/child.json")"'

echo "base: health, the merge before verify, verify and the PR diff read the recorded base"
end_run "$child"
printf 'own\n' > "$worktree/own.txt" && git -C "$worktree" add own.txt && git -C "$worktree" commit -qm own
remote_commit main main-one.txt; remote_commit main main-two.txt
remote_commit "$epic_branch" epic-a.txt; remote_commit "$epic_branch" epic-b.txt
"$plugin/scripts/steward.sh" health > "$work/health.out" 2>&1; git fetch -q origin
# main_drift: the commits main has that the epic lacks; an epic child must lack every one.
main_drift() { git rev-list --count "origin/$epic_branch..origin/main"; }
check "HealthOnEpicChildBehindItsEpic_MergesTheEpicIn: health brings the epic's new commits onto a branch more than behind_base commits behind its recorded base" \
  '[ -f "$worktree/epic-b.txt" ]'
check "HealthOnEpicChild_MainIsAheadOfTheEpic: main must hold commits the epic lacks, or the next check proves nothing" \
  '[ "$(main_drift)" -gt 0 ]'
check "HealthOnEpicChildWhileMainIsAhead_LeavesMainOut: health merges the recorded base, never the config base, so main's own commit stays off the branch" \
  '[ "$(git -C "$worktree" rev-list --count "$task_branch..origin/main")" -eq "$(main_drift)" ]'
check "HealthOnEpicChild_EventsLogNamesTheEpicRefMerged: the events log names the ref health merged" \
  'grep -F "$task_branch" .flow/events.log | grep -qF "origin/$epic_branch"'
"$plugin/scripts/state.sh" set "$child" step=verify >/dev/null
remote_commit main main-three.txt; remote_commit "$epic_branch" epic-c.txt
"$plugin/scripts/next.sh" "$child" --json > "$work/verify.json" 2>/dev/null; git fetch -q origin
check "VerifyStepOnEpicChild_SyncMergesTheEpicIn: the merge before verify brings the epic's newest commit onto the branch" \
  '[ -f "$worktree/epic-c.txt" ]'
check "VerifyStepOnEpicChild_SyncLineNamesTheEpicRef: the events log's sync line names the recorded base it merged" \
  'grep "	$child	sync	" .flow/events.log | grep -qF "origin/$epic_branch"'
check "VerifyStepOnEpicChild_MainIsAheadOfTheEpic: main must hold commits the epic lacks, or the next check proves nothing" \
  '[ "$(main_drift)" -gt 0 ]'
check "VerifyStepOnEpicChildWhileMainIsAhead_SyncLeavesMainOut: the merge before verify never brings main's commits onto an epic child" \
  '[ "$(git -C "$worktree" rev-list --count "$task_branch..origin/main")" -eq "$(main_drift)" ]'
(cd "$worktree" && "$plugin/scripts/verify.sh" "$child" >/dev/null 2>&1)
check "VerifyOnEpicChild_ChangedFilesAreOnlyTheItemsOwn: verify.sh diffs against the recorded base, so the epic's files are not counted as the item's" \
  '[ "$(json_value changed_files < "$("$plugin/scripts/steward.sh" reports "$child")/verify.json")" = "[\"own.txt\"]" ]'
git -C "$worktree" fetch -q origin
check "PrDiffProxyOfEpicChildWhileMainIsAhead_ListsOnlyTheItemsOwnFile: git diff base...branch, the diff a PR against the recorded base shows, has the one file the item made, not main's drift" \
  '[ "$(git -C "$worktree" diff --name-only "origin/$epic_branch...$task_branch")" = own.txt ]'

echo "base: the hold-release note names the recorded base"
holder="$(new_task "Ball model")"
held="$(new_task "Spin drag" "$epic")"
"$plugin/scripts/next.sh" "$held" >/dev/null 2>&1
end_run "$held"
"$plugin/scripts/hold.sh" set "$held" "$holder" "both change the ball" >/dev/null
"$local_adapter/close.sh" "$holder" >/dev/null
"$plugin/scripts/next.sh" "$held" --json > "$work/held.json" 2>/dev/null
awk '/^## The hold is over/ { on = 1; next } /^## / { on = 0 } on' "$(json_value brief < "$work/held.json")" > "$work/hold.section"
check "HeldEpicChildReleased_NoteNamesOnlyTheEpicBranch: the release note has the agent merge the recorded base and no other ref, so an epic child is never sent to merge the config base" \
  '[ "$(grep -oE "origin/[A-Za-z0-9._/-]*[A-Za-z0-9_-]" "$work/hold.section" | sort -u)" = "origin/$epic_branch" ]'

echo "base: the board and init name the base"
plain="$(new_task "Plain docs")"
"$plugin/scripts/next.sh" "$plain" >/dev/null 2>&1
"$plugin/scripts/board.sh" 2>/dev/null > "$work/board.txt"
check "BoardWithEpicChild_RowShowsItsBase: the board names a base that is not the config base beside the worktree" \
  'awk -v row="| $child |" "index(\$0, row) == 1" "$work/board.txt" | grep -qF "base $epic_branch"'
awk -v row="| $plain |" 'index($0, row) == 1' "$work/board.txt" > "$work/plain.row"
plain_cell="$(awk -F'|' '{ gsub(/^ +| +$/, "", $9); print $9 }' "$work/plain.row")"
check "BoardWithConfigBaseItem_WorktreeCellIsTheBareWorktree: an item on the config base gets no base marker beside its worktree" \
  '[ "$plain_cell" = "$(basename "$("$plugin/scripts/steward.sh" find "$plain")")" ]'
"$plugin/scripts/board.sh" --json 2>/dev/null > "$work/board.json"
check "BoardJsonWithEpicChild_PoolEntryCarriesTheBase: the board model's pool entry for the claim names its recorded base" \
  'python3 -c "import json,sys; entries=[pool_entry for pool_entry in json.load(open(sys.argv[1]))[\"pool\"] if pool_entry.get(\"item\")==sys.argv[2]]; assert entries and entries[0][\"base\"]==sys.argv[3], entries" "$work/board.json" "$child" "$epic_branch"'
git -C "$root/other" push -q origin --delete "$epic_branch"
git fetch -q --prune origin
"$plugin/scripts/board.sh" --json 2>/dev/null > "$work/board.gone.json"
check "BoardJsonAfterTheEpicBranchIsDeleted_MarksTheBaseMissing: a recorded base gone from the remote is flagged on its pool entry" \
  'python3 -c "import json,sys; entries=[pool_entry for pool_entry in json.load(open(sys.argv[1]))[\"pool\"] if pool_entry.get(\"item\")==sys.argv[2]]; assert entries and entries[0][\"base_missing\"] is True, entries" "$work/board.gone.json" "$child"'
"$plugin/scripts/board.sh" 2>/dev/null | awk '/^#+ Health/ { on = 1; next } /^#/ { on = 0 } on' > "$work/board.health"
check "BoardAfterTheEpicBranchIsDeleted_HealthNamesTheMissingBase: the board's Health section names the item and the base gone from the remote" \
  'grep -F "$child" "$work/board.health" | grep -qF "$epic_branch"'
"$plugin/skills/init/scripts/init.sh" --check > "$work/init.out" 2>&1
check "InitCheckAfterTheEpicBranchIsDeleted_NotesTheMissingBase: init --check has a note naming the item and the base gone from the remote" \
  'grep "^init: note:" "$work/init.out" | grep -F "$child" | grep -qF "$epic_branch"'

echo "base: a claim.json base that is not a safe name never reaches the board or init"
for tampered_label in $tampered_labels; do
  eval "tampered_name=\"\$$tampered_label\""
  set_claim_base "$plain" "$tampered_name"
  "$plugin/scripts/board.sh" --json 2>/dev/null > "$work/board.tampered.json"
  "$plugin/scripts/board.sh" 2>/dev/null | awk '/^#+ Health/ { on = 1; next } /^#/ { on = 0 } on' > "$work/board.tampered.health"
  "$plugin/skills/init/scripts/init.sh" --check > "$work/init.tampered.out" 2>&1
  check "BoardJsonWithATamperedClaimBase_StillFlagsTheOtherMissingBase [$tampered_label]: one bad claim.json does not break the bases the board reads for every other claim" \
    '[ "$(pool_entry_field "$work/board.tampered.json" "$child" base_missing)" = true ]'
  check "BoardJsonWithATamperedClaimBase_GivesThatClaimNoBase [$tampered_label]: the board skips a recorded base that fails the name check, so its text never reaches the board" \
    '[ "$(pool_entry_field "$work/board.tampered.json" "$plain" base)" = "\"\"" ]'
  check "BoardWithATamperedClaimBase_HealthNamesTheChild [$tampered_label]: the health section must list the claims, or the next check proves nothing" \
    'grep -qF "$child" "$work/board.tampered.health"'
  check "BoardWithATamperedClaimBase_HealthNamesNoForgedItem [$tampered_label]: a line break in the base cannot add a record for an item no pool worktree claims" \
    '! grep -qF forged-item "$work/board.tampered.health"'
  check "InitCheckWithATamperedClaimBase_StillNotesTheOtherMissingBase [$tampered_label]: one bad claim.json does not stop init noting another claim's missing base" \
    'grep "^init: note:" "$work/init.tampered.out" | grep -F "$child" | grep -qF "$epic_branch"'
  check "InitCheckWithATamperedClaimBase_NamesTheChild [$tampered_label]: init must note the claims, or the next check proves nothing" \
    'grep -qF "$child" "$work/init.tampered.out"'
  check "InitCheckWithATamperedClaimBase_NotesNoForgedItem [$tampered_label]: a line break in the base cannot add a note for an item no pool worktree claims" \
    '! grep -qF forged-item "$work/init.tampered.out"'
done

[ "$fails" -eq 0 ] && { echo "base-readers: ok"; exit 0; }
echo "base-readers: $fails failed"; exit 1
