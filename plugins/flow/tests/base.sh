#!/bin/sh
# base.sh: an item's base branch is resolved once at claim and used by every reader, on the local
# adapter in throwaway repos with a bare origin. A new claim starts from the parent's claimed
# branch, else the nearest ancestor's epic/<n> on the remote, else a base: line in the body, else
# the config base, and records it in claim.json and state.base; a base: line naming a missing
# branch passes the item over. Health, the merge before verify, verify.sh, the brief, the JSON,
# the hold-release note, the board and init --check all read the recorded base.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
plugin="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$plugin"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
unset FLOW_SLACK_WEBHOOK FLOW_HOME
mkdir -p "$work/home" "$work/offline" && HOME="$work/home" && export HOME && unset CODEX_HOME
for tool in curl wget gh osascript notify-send claude codex launchctl; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/offline.log"\n' "$tool" "$work" > "$work/offline/$tool"
  chmod +x "$work/offline/$tool"
done
PATH="$work/offline:$PATH"; export PATH
export FLOW_HEALTH_PROCS="$work/procs"; : > "$FLOW_HEALTH_PROCS"
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { # check <name> '<condition>': the condition is shell text, run whole; a FAIL shows its output
  if said="$( (eval "$2") 2>&1)"; then pass "$1"; else fail "$1"; [ -z "$said" ] || printf '%s\n' "$said" | sed 's/^/       /'; fi
}
json_value() { python3 -c 'import json,sys; value=json.load(sys.stdin)
for key in sys.argv[1].split("."): value = value[int(key)] if key.isdigit() else value[key]
print(value if isinstance(value,str) else json.dumps(value))' "$1"; }
local_adapter="$plugin/adapters/local"
slug() { printf '%s' "$1" | tr ':/#' '---'; }
run_file() { printf '.flow/runs/%s.json' "$(slug "$1")"; }
state() { "$local_adapter/read.sh" "$1" | json_value "state.$2"; }
claim_base() { json_value base < "$("$plugin/scripts/steward.sh" find "$1")/.flow/claim.json"; }
# set_claim_base <item> <name>: writes <name> as the base in the item's claim.json, as a hand could.
set_claim_base() { python3 -c 'import json,sys; path=sys.argv[1]; claim=json.load(open(path)); claim["base"]=sys.argv[2]; json.dump(claim,open(path,"w"))' "$("$plugin/scripts/steward.sh" find "$1")/.flow/claim.json" "$2"; }
# pool_entry_field <board-json> <item> <field>: the field of the item's pool entry, as JSON.
pool_entry_field() { python3 -c 'import json,sys; entries=[pool_entry for pool_entry in json.load(open(sys.argv[1]))["pool"] if pool_entry.get("item")==sys.argv[2]]; print(json.dumps(entries[0][sys.argv[3]]) if entries else "no pool entry")' "$@"; }
# The reason a claim gives for a base: name base_name_valid refuses, read from lib/base.sh.
base_name_refused="$(sh -c '. "$FLOW_PLUGIN/lib/flow.sh" && . "$FLOW_PLUGIN/lib/base.sh" && printf %s "$base_name_refused"')"
# epic_of <id>: the epic branch an id names, worked out by hand from the rule: the id past its
# last #, / or :, after epic/.
epic_of() { printf 'epic/%s' "$(printf '%s' "$1" | sed 's|.*[#/:]||')"; }
# The names no reader may hand on from a claim.json base, and no claim may record, by label. A tab
# shifts the fields of a claimed_bases record; the line breaks end one record and forge the next.
name_with_a_tab="$(printf 'plan/x\ty')"; name_with_a_shell_character='plan/x;id'
name_forging_a_record="$(printf 'plan/x\t/tmp\tfalse\nforged-item\tforged-base\t/tmp\ttrue\nleftover')"
name_git_reads_as_an_option='-x'; name_with_a_space='plan/x y'; name_climbing_a_level='plan/../x'
name_from_the_root='/plan/x'; name_with_a_letter_outside_ascii='plan/é'
tampered_labels="name_with_a_tab name_forging_a_record name_with_a_shell_character name_git_reads_as_an_option
  name_with_a_space name_climbing_a_level name_from_the_root name_with_a_letter_outside_ascii"

# new_repo <dir>: a clone of a fresh bare origin, on the local adapter with config base main, a
# three-worktree pool and behind_base 1; the shell in it. other is a second clone that moves the
# remote.
new_repo() {
  root="$work/$1"; mkdir -p "$root" && git init -q --bare "$root/origin.git" || exit 1
  git clone -q "$root/origin.git" "$root/app" 2>/dev/null && cd "$root/app" || exit 1
  git config user.email t@t && git config user.name t && git symbolic-ref HEAD refs/heads/main
  printf 'hi\n' > README.md && git add -A && git commit -qm init && git push -q -u origin main
  for worktree_number in 1 2 3; do git worktree add -q -b "main-wt-$worktree_number" "../wt-$worktree_number"; done
  mkdir -p .flow
  printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\n  - ../wt-3\npool_max: 8\nnotify:\n  desktop: false\njobs:\n  health:\n    behind_base: 1\n' > .flow/config.yaml
  git clone -q "$root/origin.git" "$root/other" 2>/dev/null
  git -C "$root/other" config user.email t@t && git -C "$root/other" config user.name t
}
# remote_branch <branch>: a new branch on the remote at main's tip.
remote_branch() { git -C "$root/other" fetch -q origin && git -C "$root/other" push -q origin "origin/main:refs/heads/$1"; }
# remote_commit <branch> <file>: one commit adding <file> on the remote <branch>.
remote_commit() { git -C "$root/other" fetch -q origin && git -C "$root/other" checkout -q -B "$1" "origin/$1" && printf '%s\n' "$2" > "$root/other/$2" && git -C "$root/other" add -- "$2" && git -C "$root/other" commit -qm "$2" && git -C "$root/other" push -q origin "$1"; }
body="## Acceptance
- [ ] done"
new_task() { "$plugin/scripts/new.sh" task "$1" --size S --body "${3:-$body}" ${2:+--parent "$2"}; }
move_task_numbers_past_the_epic_numbers() { for filler in "$@"; do "$local_adapter/create.sh" task "Filler $filler" --body x >/dev/null; done; }

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
rm -f "$(run_file "$child")"
printf 'own\n' > "$worktree/own.txt" && git -C "$worktree" add own.txt && git -C "$worktree" commit -qm own
remote_commit main main-one.txt; remote_commit main main-two.txt
remote_commit "$epic_branch" epic-a.txt; remote_commit "$epic_branch" epic-b.txt
"$plugin/scripts/steward.sh" health > "$work/health.out" 2>&1; git fetch -q origin
# main_drift: the commits main has that the epic lacks; an epic child must lack every one.
main_drift() { git rev-list --count "origin/$epic_branch..origin/main"; }
check "HealthOnEpicChildBehindItsEpic_MergesTheEpicIn: health brings the epic's new commits onto a branch more than behind_base commits behind its recorded base" \
  '[ -f "$worktree/epic-b.txt" ]'
check "HealthOnEpicChildWhileMainIsAhead_LeavesMainOut: health merges the recorded base, never the config base, so main's own commit stays off the branch" \
  'drift="$(main_drift)"; [ "$drift" -gt 0 ] && [ "$(git -C "$worktree" rev-list --count "$task_branch..origin/main")" -eq "$drift" ]'
check "HealthOnEpicChild_EventsLogNamesTheEpicRefMerged: the events log names the ref health merged" \
  'grep -F "$task_branch" .flow/events.log | grep -qF "origin/$epic_branch"'
"$local_adapter/write-state.sh" "$child" step=verify >/dev/null
remote_commit main main-three.txt; remote_commit "$epic_branch" epic-c.txt
"$plugin/scripts/next.sh" "$child" --json > "$work/verify.json" 2>/dev/null; git fetch -q origin
check "VerifyStepOnEpicChild_SyncMergesTheEpicIn: the merge before verify brings the epic's newest commit onto the branch" \
  '[ -f "$worktree/epic-c.txt" ]'
check "VerifyStepOnEpicChild_SyncLineNamesTheEpicRef: the events log's sync line names the recorded base it merged" \
  'grep "	$child	sync	" .flow/events.log | grep -qF "origin/$epic_branch"'
check "VerifyStepOnEpicChildWhileMainIsAhead_SyncLeavesMainOut: the merge before verify never brings main's commits onto an epic child" \
  'drift="$(main_drift)"; [ "$drift" -gt 0 ] && [ "$(git -C "$worktree" rev-list --count "$task_branch..origin/main")" -eq "$drift" ]'
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
rm -f "$(run_file "$held")"
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
  check "BoardWithATamperedClaimBase_HealthNamesNoForgedItem [$tampered_label]: a line break in the base cannot add a record for an item no pool worktree claims" \
    'grep -qF "$child" "$work/board.tampered.health" && ! grep -qF forged-item "$work/board.tampered.health"'
  check "InitCheckWithATamperedClaimBase_StillNotesTheOtherMissingBase [$tampered_label]: one bad claim.json does not stop init noting another claim's missing base" \
    'grep "^init: note:" "$work/init.tampered.out" | grep -F "$child" | grep -qF "$epic_branch"'
  check "InitCheckWithATamperedClaimBase_NotesNoForgedItem [$tampered_label]: a line break in the base cannot add a note for an item no pool worktree claims" \
    'grep -qF "$child" "$work/init.tampered.out" && ! grep -qF forged-item "$work/init.tampered.out"'
done

echo "base: where a claim starts when there is no epic branch next to it"
new_repo walk
grandparent_epic="$("$local_adapter/create.sh" epic "Drills" --size L --body x)"
grandparent_epic_branch="$(epic_of "$grandparent_epic")"
remote_branch "$grandparent_epic_branch"; remote_commit "$grandparent_epic_branch" drills.txt
move_task_numbers_past_the_epic_numbers one two
middle="$(new_task "Drill set" "$grandparent_epic")"
grandchild="$(new_task "Drill timer" "$middle")"
"$plugin/scripts/next.sh" "$grandchild" >/dev/null 2>&1
check "GrandchildWhoseParentHasNoEpicBranch_TakesTheGrandparentsEpicBranch: the walk goes up past a parent with no epic/<n> to the nearest ancestor that has one" \
  '[ "$(claim_base "$grandchild")" = "$grandparent_epic_branch" ]'
parent="$(new_task "Tuning instrument")"
"$plugin/scripts/steward.sh" claim "$parent" >/dev/null 2>&1
competing_epic_branch="$(epic_of "$parent")"
remote_branch "$competing_epic_branch"
kid="$(new_task "Tuning panel" "$parent")"
"$plugin/scripts/next.sh" "$kid" >/dev/null 2>&1
check "ChildOfAClaimedParentThatAlsoHasAnEpicBranch_TakesTheParentsTaskBranch: a parent's claimed branch comes before any epic branch, so the child's PR lands on its parent's work" \
  '[ "$(claim_base "$kid")" = "flow/$(slug "$parent")" ]'
lined_kid="$(new_task "Tuning readout" "$parent" "base: plan/sandbox
$body")"
remote_branch plan/sandbox; remote_commit plan/sandbox plan.txt
"$plugin/scripts/next.sh" "$lined_kid" >/dev/null 2>&1
check "ChildOfAClaimedParentWithABaseLine_TakesTheParentsTaskBranch: a parent's claimed branch comes before a base: line, so the child's PR lands on its parent's work" \
  '[ "$(claim_base "$lined_kid")" = "flow/$(slug "$parent")" ]'
ruled="$(new_task "Drill scoring" "$grandparent_epic" "base: plan/sandbox
$body")"
"$plugin/scripts/next.sh" "$ruled" >/dev/null 2>&1
check "EpicChildWithABaseLine_TakesTheEpicBranch: an ancestor's epic branch comes before a base: line, so a child of an epic stays on the epic" \
  '[ "$(claim_base "$ruled")" = "$grandparent_epic_branch" ]'
lined="$(new_task "Sandbox plan" "" "base: plan/sandbox
$body")"
"$plugin/scripts/next.sh" "$lined" >/dev/null 2>&1; git fetch -q origin
check "NoParentWithABaseLine_ClaimJsonRecordsThatBranch: an item with no parent link takes the branch its base: line names" \
  '[ "$(claim_base "$lined")" = plan/sandbox ]'
check "NoParentWithABaseLine_BranchDescendsFromIt: the claim starts from the named branch, so its commit is on the task branch" \
  'git -C "$("$plugin/scripts/steward.sh" find "$lined")" merge-base --is-ancestor origin/plan/sandbox HEAD'
loose="$(new_task "Loose docs")"
"$plugin/scripts/next.sh" "$loose" >/dev/null 2>&1
check "NoParentNoBaseLine_TakesTheConfigBase: with nothing else to go on the claim starts from the config base" \
  '[ "$(claim_base "$loose")" = main ]'
bare="$("$local_adapter/create.sh" epic "No branch yet" --size L --body x)"
move_task_numbers_past_the_epic_numbers three four
orphan="$(new_task "Early slice" "$bare")"
"$plugin/scripts/next.sh" "$orphan" >/dev/null 2>&1
check "ChildOfAnEpicWithNoEpicBranch_TakesTheConfigBase: an epic whose epic/<n> is not on the remote gives no base, so the claim falls through" \
  '[ "$(claim_base "$orphan")" = main ]'

echo "base: a base: line naming a missing branch passes the item over"
missing="$(new_task "Gone plan" "" "base: plan/gone
$body")"
"$plugin/scripts/next.sh" "$missing" >/dev/null 2>&1; code=$?
check "BaseLineNamingAMissingBranch_NamedRunExitsWithThePassOverCode: a named run of an item whose base is not on the remote exits 4" \
  '[ "$code" -eq 4 ]'
check "BaseLineNamingAMissingBranch_ClaimsNoWorktree: the item is never claimed from the config base instead" \
  '[ -z "$("$plugin/scripts/steward.sh" find "$missing")" ]'
check "BaseLineNamingAMissingBranch_LastEventNamesTheBranch: the owner sees which base is missing" \
  'state "$missing" last_event | grep -qF plan/gone'
for unsafe_name in "$name_with_a_shell_character" "$name_git_reads_as_an_option" \
  "$name_climbing_a_level" "$name_from_the_root" "$name_with_a_letter_outside_ascii"; do
  unsafe="$(new_task "Odd plan $unsafe_name" "" "base: $unsafe_name
$body")"
  "$plugin/scripts/next.sh" "$unsafe" >/dev/null 2>&1; unsafe_code=$?
  check "BaseLineOutsideTheSafeNames_ClaimsNoWorktree [$unsafe_name]: a base: name outside the safe set is refused, never claimed from the config base, so it cannot reach a brief or a git command" \
    '[ -z "$("$plugin/scripts/steward.sh" find "$unsafe")" ]'
  check "BaseLineOutsideTheSafeNames_NamedRunExitsWithThePassOverCode [$unsafe_name]: a refused base passes the item over like a missing one" \
    '[ "$unsafe_code" -eq 4 ]'
  check "BaseLineOutsideTheSafeNames_LastEventSaysTheNameIsNotValid [$unsafe_name]: the owner sees the base was refused as a name, not reported missing from the remote" \
    '[ -n "$base_name_refused" ] && state "$unsafe" last_event | grep -qF -- "$base_name_refused"'
  check "BaseLineOutsideTheSafeNames_LastEventLeavesTheNameOut [$unsafe_name]: a refused name may carry control characters, so it never reaches last_event" \
    'last_event="$(state "$unsafe" last_event)"; [ -n "$last_event" ] && ! printf "%s\n" "$last_event" | grep -qF -- "$unsafe_name"'
done
spaced="$(new_task "Spaced plan" "" "base: $name_with_a_space
$body")"
"$plugin/scripts/next.sh" "$spaced" >/dev/null 2>&1; spaced_code=$?
check "BaseLineWithASpace_ClaimsNoWorktree: the body parser ends the name at the first blank, and plan/x is not on the remote, so nothing is claimed" \
  '[ -z "$("$plugin/scripts/steward.sh" find "$spaced")" ]'
check "BaseLineWithASpace_NamedRunExitsWithThePassOverCode: the cut name is missing, so the item is passed over" \
  '[ "$spaced_code" -eq 4 ]'
check "BaseLineWithASpace_LastEventNamesTheNameCutAtTheSpace: the owner sees the branch the claim looked for, the name up to the blank" \
  'state "$spaced" last_event | grep -qF -- "${name_with_a_space%% *}"'

echo "base: a recorded base that is not a safe name is never handed on"
loose_worktree="$("$plugin/scripts/steward.sh" find "$loose")"
printf 'loose\n' > "$loose_worktree/loose.txt" && git -C "$loose_worktree" add loose.txt && git -C "$loose_worktree" commit -qm loose
for tampered_label in $tampered_labels; do
  eval "tampered_name=\"\$$tampered_label\""
  set_claim_base "$loose" "$tampered_name"
  rm -f "$(run_file "$loose")"
  "$plugin/scripts/next.sh" "$loose" --json > "$work/tampered.json" 2>/dev/null
  check "TamperedClaimBase_JsonBaseIsTheConfigBase [$tampered_label]: next.sh checks the name claim.json records and falls back to the config base, so a bad name never reaches the runner or git" \
    '[ "$(json_value base < "$work/tampered.json")" = main ]'
  set_claim_base "$loose" "$tampered_name"
  rm -f "$("$plugin/scripts/steward.sh" reports "$loose")/verify.json"
  (cd "$loose_worktree" && "$plugin/scripts/verify.sh" "$loose" >/dev/null 2>&1)
  check "TamperedClaimBase_VerifyDiffsAgainstTheConfigBase [$tampered_label]: verify.sh checks the name claim.json records and measures the item's own files from the config base" \
    '[ "$(json_value changed_files < "$("$plugin/scripts/steward.sh" reports "$loose")/verify.json")" = "[\"loose.txt\"]" ]'
done

echo "base: steward's own claim refuses a base that is not a safe name"
direct="$(new_task "Direct claim")"
for tampered_label in $tampered_labels; do
  eval "tampered_name=\"\$$tampered_label\""
  "$plugin/scripts/steward.sh" claim "$direct" --base "$tampered_name" >/dev/null 2>&1; direct_code=$?
  check "StewardClaimWithAnUnsafeBase_ExitsWithTheUsageCode [$tampered_label]: a caller other than next.sh cannot record a base that fails the name check" \
    '[ "$direct_code" -eq 2 ]'
  check "StewardClaimWithAnUnsafeBase_ClaimsNoWorktree [$tampered_label]: the refused claim leaves the item with no pool worktree" \
    '[ -z "$("$plugin/scripts/steward.sh" find "$direct")" ]'
done

echo "base: a letter outside ASCII is refused in a UTF-8 locale too"
# A UTF-8 locale lets a letter outside ASCII through the ranges A-Za-z, so the refusal rows run
# in one. C and some C.UTF-8 builds refuse it with no check at all, so they would pass on nothing.
# A fresh repo, so a full pool cannot pass the item over in place of the name check.
new_repo accented
locale_letting_the_letter_through=en_US.UTF-8
check "UnicodeLocale_LetsTheLetterThroughTheRanges: the rows below can only fail when the locale lets the letter through the ranges" \
  '[ "$(LC_ALL=$locale_letting_the_letter_through sh -c "case \"\$1\" in *[!A-Za-z0-9._/-]*) echo refused ;; *) echo let-through ;; esac" sh "$name_with_a_letter_outside_ascii")" = let-through ]'
remote_branch "$name_with_a_letter_outside_ascii"
accented="$(new_task "Accented plan" "" "base: $name_with_a_letter_outside_ascii
$body")"
LC_ALL=$locale_letting_the_letter_through "$plugin/scripts/next.sh" "$accented" >/dev/null 2>&1; accented_code=$?
check "BaseLineWithALetterOutsideAsciiInAUnicodeLocale_ClaimsNoWorktree: the branch is on the remote, but its name is refused whatever the locale" \
  '[ -z "$("$plugin/scripts/steward.sh" find "$accented")" ]'
check "BaseLineWithALetterOutsideAsciiInAUnicodeLocale_NamedRunExitsWithThePassOverCode: a refused base passes the item over like a missing one" \
  '[ "$accented_code" -eq 4 ]'
check "BaseLineWithALetterOutsideAsciiInAUnicodeLocale_LastEventSaysTheNameIsNotValid: the refusal is the name check, not a missing branch" \
  '[ -n "$base_name_refused" ] && state "$accented" last_event | grep -qF -- "$base_name_refused"'
accented_direct="$(new_task "Accented direct claim")"
LC_ALL=$locale_letting_the_letter_through "$plugin/scripts/steward.sh" claim "$accented_direct" --base "$name_with_a_letter_outside_ascii" >/dev/null 2>&1; accented_direct_code=$?
check "StewardClaimWithALetterOutsideAsciiInAUnicodeLocale_ExitsWithTheUsageCode: steward's own claim refuses the name whatever the locale" \
  '[ "$accented_direct_code" -eq 2 ]'

echo "base: the epic walk stops at a parent id no adapter owns"
# A parent id with no adapter prefix is read as an adapter name, so a path there would run any
# read.sh it points at. The planted one leaves a mark when it runs.
new_repo stray
mkdir -p "$work/planted"
cat > "$work/planted/read.sh" <<PLANTED
#!/bin/sh
: > "$work/planted.ran"
echo '{"id": "planted", "kind": "epic", "parent": "", "state": {}}'
PLANTED
chmod +x "$work/planted/read.sh"
climb_to_the_root=""; for level in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do climb_to_the_root="$climb_to_the_root../"; done
parent_id_no_adapter_owns="$climb_to_the_root${work#/}/planted"
check "PlantedRead_RunsWhenCalled: the planted script leaves its mark, so its absence below means it never ran" \
  '"$work/planted/read.sh" >/dev/null && [ -e "$work/planted.ran" ] && rm -f "$work/planted.ran"'
stray="$("$local_adapter/create.sh" task "Stray child" --size S --body "$body" --parent "$parent_id_no_adapter_owns")"
"$plugin/scripts/next.sh" "$stray" >/dev/null 2>&1
check "ChildOfAParentIdNoAdapterOwns_RunsNothingAtThatPath: the walk stops at the id, so the file it names never runs" \
  '[ ! -e "$work/planted.ran" ]'
check "ChildOfAParentIdNoAdapterOwns_TakesTheConfigBase: the walk finds no epic past the id, so the claim falls through to the config base" \
  '[ "$(claim_base "$stray")" = main ]'

[ "$fails" -eq 0 ] && { echo "base: ok"; exit 0; }
echo "base: $fails failed"; exit 1
