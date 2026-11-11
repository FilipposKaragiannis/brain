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
P="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$P"
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
jget() { python3 -c 'import json,sys; v=json.load(sys.stdin)
for k in sys.argv[1].split("."): v = v[int(k)] if k.isdigit() else v[k]
print(v if isinstance(v,str) else json.dumps(v))' "$1"; }
L="$P/adapters/local"
slug() { printf '%s' "$1" | tr ':/#' '---'; }
run_file() { printf '.flow/runs/%s.json' "$(slug "$1")"; }
state() { "$L/read.sh" "$1" | jget "state.$2"; }
claim_base() { jget base < "$("$P/scripts/steward.sh" find "$1")/.flow/claim.json"; }
# epic_of <id>: the epic branch an id names, worked out by hand from the rule: the id past its
# last #, / or :, after epic/.
epic_of() { printf 'epic/%s' "$(printf '%s' "$1" | sed 's|.*[#/:]||')"; }

# new_repo <dir>: a clone of a fresh bare origin, on the local adapter with config base main, a
# three-worktree pool and behind_base 1; the shell in it. other is a second clone that moves the
# remote.
new_repo() {
  root="$work/$1"; mkdir -p "$root" && git init -q --bare "$root/origin.git" || exit 1
  git clone -q "$root/origin.git" "$root/app" 2>/dev/null && cd "$root/app" || exit 1
  git config user.email t@t && git config user.name t && git symbolic-ref HEAD refs/heads/main
  printf 'hi\n' > README.md && git add -A && git commit -qm init && git push -q -u origin main
  for n in 1 2 3; do git worktree add -q -b "main-wt-$n" "../wt-$n"; done
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
new_task() { "$P/scripts/new.sh" task "$1" --size S --body "${3:-$body}" ${2:+--parent "$2"}; }
move_task_numbers_past_the_epic_numbers() { for filler in "$@"; do "$L/create.sh" task "Filler $filler" --body x >/dev/null; done; }

echo "base: a child of an epic is claimed from the epic branch"
new_repo epic
epic="$("$L/create.sh" epic "Physics" --size L --body x)"
eb="$(epic_of "$epic")"
remote_branch "$eb"; remote_commit "$eb" epic-start.txt
child="$(new_task "Ball spin" "$epic")"
"$P/scripts/next.sh" "$child" --json > "$work/child.json" 2>/dev/null
wt="$("$P/scripts/steward.sh" find "$child")"; br="flow/$(slug "$child")"; git fetch -q origin
check "EpicChild_BranchDescendsFromTheEpicBranch: a child of an epic whose epic/<n> is on the remote starts from it, so the epic's own commit is on the branch right after the claim" \
  'git -C "$wt" merge-base --is-ancestor "origin/$eb" "$br"'
check "EpicChild_ClaimJsonRecordsTheEpicBranch: claim.json carries the base every reader in the worktree takes" \
  '[ "$(claim_base "$child")" = "$eb" ]'
check "EpicChild_ItemStateRecordsTheEpicBranch: state.base carries the base for a step that has no worktree" \
  '[ "$(state "$child" base)" = "$eb" ]'
check "EpicChild_EventsLogNamesTheBaseOfTheClaim: the claim says which base it started from" \
  'grep "	$child	claim	" .flow/events.log | grep -qF "$eb"'
check "EpicChild_JsonBaseIsTheEpicBranch: next.sh --json hands the runner the recorded base, not the config base" \
  '[ "$(jget base < "$work/child.json")" = "$eb" ]'
check "EpicChild_BriefNamesTheEpicBranchAsBase: the brief tells the agent the recorded base" \
  'grep -qF "\`$eb\`" "$(jget brief < "$work/child.json")"'

echo "base: health, the merge before verify, verify and the PR diff read the recorded base"
rm -f "$(run_file "$child")"
printf 'own\n' > "$wt/own.txt" && git -C "$wt" add own.txt && git -C "$wt" commit -qm own
remote_commit main main-one.txt; remote_commit main main-two.txt
remote_commit "$eb" epic-a.txt; remote_commit "$eb" epic-b.txt
"$P/scripts/steward.sh" health > "$work/health.out" 2>&1
check "HealthOnEpicChildBehindItsEpic_MergesTheEpicIn: health brings the epic's new commits onto a branch more than behind_base commits behind its recorded base" \
  '[ -f "$wt/epic-b.txt" ]'
check "HealthOnEpicChildWhileMainIsAhead_LeavesMainOut: health merges the recorded base, never the config base, so main's own commit stays off the branch" \
  '[ "$(git -C "$wt" rev-list --count "$br..origin/main")" -eq 2 ]'
check "HealthOnEpicChild_EventsLogNamesTheEpicRefMerged: the events log names the ref health merged" \
  'grep -F "$br" .flow/events.log | grep -qF "origin/$eb"'
"$L/write-state.sh" "$child" step=verify >/dev/null
remote_commit main main-three.txt; remote_commit "$eb" epic-c.txt
"$P/scripts/next.sh" "$child" --json > "$work/verify.json" 2>/dev/null; git fetch -q origin
check "VerifyStepOnEpicChild_SyncMergesTheEpicIn: the merge before verify brings the epic's newest commit onto the branch" \
  '[ -f "$wt/epic-c.txt" ]'
check "VerifyStepOnEpicChild_SyncLineNamesTheEpicRef: the events log's sync line names the recorded base it merged" \
  'grep "	$child	sync	" .flow/events.log | grep -qF "origin/$eb"'
check "VerifyStepOnEpicChildWhileMainIsAhead_SyncLeavesMainOut: the merge before verify never brings main's commits onto an epic child" \
  '[ "$(git -C "$wt" rev-list --count "$br..origin/main")" -eq 3 ]'
(cd "$wt" && "$P/scripts/verify.sh" "$child" >/dev/null 2>&1)
check "VerifyOnEpicChild_ChangedFilesAreOnlyTheItemsOwn: verify.sh diffs against the recorded base, so the epic's files are not counted as the item's" \
  '[ "$(jget changed_files < "$("$P/scripts/steward.sh" reports "$child")/verify.json")" = "[\"own.txt\"]" ]'
git -C "$wt" fetch -q origin
check "PrDiffProxyOfEpicChildWhileMainIsAhead_ListsOnlyTheItemsOwnFile: git diff base...branch, the diff a PR against the recorded base shows, has the one file the item made, not main's drift" \
  '[ "$(git -C "$wt" diff --name-only "origin/$eb...$br")" = own.txt ]'

echo "base: the hold-release note names the recorded base"
holder="$(new_task "Ball model")"
held="$(new_task "Spin drag" "$epic")"
"$P/scripts/next.sh" "$held" >/dev/null 2>&1
rm -f "$(run_file "$held")"
"$P/scripts/hold.sh" set "$held" "$holder" "both change the ball" >/dev/null
"$L/close.sh" "$holder" >/dev/null
"$P/scripts/next.sh" "$held" --json > "$work/held.json" 2>/dev/null
awk '/^## The hold is over/ { on = 1; next } /^## / { on = 0 } on' "$(jget brief < "$work/held.json")" > "$work/hold.section"
check "HeldEpicChildReleased_NoteNamesOnlyTheEpicBranch: the release note has the agent merge the recorded base and no other ref, so an epic child is never sent to merge the config base" \
  '[ "$(grep -oE "origin/[A-Za-z0-9._/-]*[A-Za-z0-9_-]" "$work/hold.section" | sort -u)" = "origin/$eb" ]'

echo "base: the board and init name the base"
plain="$(new_task "Plain docs")"
"$P/scripts/next.sh" "$plain" >/dev/null 2>&1
"$P/scripts/board.sh" 2>/dev/null > "$work/board.txt"
check "BoardWithEpicChild_RowShowsItsBase: the board names a base that is not the config base beside the worktree" \
  'awk -v row="| $child |" "index(\$0, row) == 1" "$work/board.txt" | grep -qF "base $eb"'
awk -v row="| $plain |" 'index($0, row) == 1' "$work/board.txt" > "$work/plain.row"
plain_cell="$(awk -F'|' '{ gsub(/^ +| +$/, "", $9); print $9 }' "$work/plain.row")"
check "BoardWithConfigBaseItem_WorktreeCellIsTheBareWorktree: an item on the config base gets no base marker beside its worktree" \
  '[ "$plain_cell" = "$(basename "$("$P/scripts/steward.sh" find "$plain")")" ]'
"$P/scripts/board.sh" --json 2>/dev/null > "$work/board.json"
check "BoardJsonWithEpicChild_PoolEntryCarriesTheBase: the board model's pool entry for the claim names its recorded base" \
  'python3 -c "import json,sys; p=[w for w in json.load(open(sys.argv[1]))[\"pool\"] if w.get(\"item\")==sys.argv[2]]; assert p and p[0][\"base\"]==sys.argv[3], p" "$work/board.json" "$child" "$eb"'
git -C "$root/other" push -q origin --delete "$eb"
git fetch -q --prune origin
"$P/scripts/board.sh" --json 2>/dev/null > "$work/board.gone.json"
check "BoardJsonAfterTheEpicBranchIsDeleted_MarksTheBaseMissing: a recorded base gone from the remote is flagged on its pool entry" \
  'python3 -c "import json,sys; p=[w for w in json.load(open(sys.argv[1]))[\"pool\"] if w.get(\"item\")==sys.argv[2]]; assert p and p[0][\"base_missing\"] is True, p" "$work/board.gone.json" "$child"'
"$P/scripts/board.sh" 2>/dev/null | awk '/^#+ Health/ { on = 1; next } /^#/ { on = 0 } on' > "$work/board.health"
check "BoardAfterTheEpicBranchIsDeleted_HealthNamesTheMissingBase: the board's Health section names the item and the base gone from the remote" \
  'grep -F "$child" "$work/board.health" | grep -qF "$eb"'
"$P/skills/init/scripts/init.sh" --check > "$work/init.out" 2>&1
check "InitCheckAfterTheEpicBranchIsDeleted_NotesTheMissingBase: init --check has a note naming the item and the base gone from the remote" \
  'grep "^init: note:" "$work/init.out" | grep -F "$child" | grep -qF "$eb"'

echo "base: where a claim starts when there is no epic branch next to it"
new_repo walk
grand="$("$L/create.sh" epic "Drills" --size L --body x)"
gb="$(epic_of "$grand")"
remote_branch "$gb"; remote_commit "$gb" drills.txt
move_task_numbers_past_the_epic_numbers one two
middle="$(new_task "Drill set" "$grand")"
grandchild="$(new_task "Drill timer" "$middle")"
"$P/scripts/next.sh" "$grandchild" >/dev/null 2>&1
check "GrandchildWhoseParentHasNoEpicBranch_TakesTheGrandparentsEpicBranch: the walk goes up past a parent with no epic/<n> to the nearest ancestor that has one" \
  '[ "$(claim_base "$grandchild")" = "$gb" ]'
parent="$(new_task "Tuning instrument")"
"$P/scripts/steward.sh" claim "$parent" >/dev/null 2>&1
competing_epic_branch="$(epic_of "$parent")"
remote_branch "$competing_epic_branch"
kid="$(new_task "Tuning panel" "$parent")"
"$P/scripts/next.sh" "$kid" >/dev/null 2>&1
check "ChildOfAClaimedParentThatAlsoHasAnEpicBranch_TakesTheParentsTaskBranch: a parent's claimed branch comes before any epic branch, so the child's PR lands on its parent's work" \
  '[ "$(claim_base "$kid")" = "flow/$(slug "$parent")" ]'
lined_kid="$(new_task "Tuning readout" "$parent" "base: plan/sandbox
$body")"
remote_branch plan/sandbox; remote_commit plan/sandbox plan.txt
"$P/scripts/next.sh" "$lined_kid" >/dev/null 2>&1
check "ChildOfAClaimedParentWithABaseLine_TakesTheParentsTaskBranch: a parent's claimed branch comes before a base: line, so the child's PR lands on its parent's work" \
  '[ "$(claim_base "$lined_kid")" = "flow/$(slug "$parent")" ]'
ruled="$(new_task "Drill scoring" "$grand" "base: plan/sandbox
$body")"
"$P/scripts/next.sh" "$ruled" >/dev/null 2>&1
check "EpicChildWithABaseLine_TakesTheEpicBranch: an ancestor's epic branch comes before a base: line, so a child of an epic stays on the epic" \
  '[ "$(claim_base "$ruled")" = "$gb" ]'
lined="$(new_task "Sandbox plan" "" "base: plan/sandbox
$body")"
"$P/scripts/next.sh" "$lined" >/dev/null 2>&1; git fetch -q origin
check "NoParentWithABaseLine_ClaimJsonRecordsThatBranch: an item with no parent link takes the branch its base: line names" \
  '[ "$(claim_base "$lined")" = plan/sandbox ]'
check "NoParentWithABaseLine_BranchDescendsFromIt: the claim starts from the named branch, so its commit is on the task branch" \
  'git -C "$("$P/scripts/steward.sh" find "$lined")" merge-base --is-ancestor origin/plan/sandbox HEAD'
loose="$(new_task "Loose docs")"
"$P/scripts/next.sh" "$loose" >/dev/null 2>&1
check "NoParentNoBaseLine_TakesTheConfigBase: with nothing else to go on the claim starts from the config base" \
  '[ "$(claim_base "$loose")" = main ]'
bare="$("$L/create.sh" epic "No branch yet" --size L --body x)"
move_task_numbers_past_the_epic_numbers three four
orphan="$(new_task "Early slice" "$bare")"
"$P/scripts/next.sh" "$orphan" >/dev/null 2>&1
check "ChildOfAnEpicWithNoEpicBranch_TakesTheConfigBase: an epic whose epic/<n> is not on the remote gives no base, so the claim falls through" \
  '[ "$(claim_base "$orphan")" = main ]'

echo "base: a base: line naming a missing branch passes the item over"
missing="$(new_task "Gone plan" "" "base: plan/gone
$body")"
"$P/scripts/next.sh" "$missing" >/dev/null 2>&1; code=$?
check "BaseLineNamingAMissingBranch_NamedRunExitsWithThePassOverCode: a named run of an item whose base is not on the remote exits 4" \
  '[ "$code" -eq 4 ]'
check "BaseLineNamingAMissingBranch_ClaimsNoWorktree: the item is never claimed from the config base instead" \
  '[ -z "$("$P/scripts/steward.sh" find "$missing")" ]'
check "BaseLineNamingAMissingBranch_LastEventNamesTheBranch: the owner sees which base is missing" \
  'state "$missing" last_event | grep -qF plan/gone'
name_with_a_shell_character='plan/x;id'; name_git_reads_as_an_option='-x'
name_with_a_space='plan/x y'; name_climbing_a_level='plan/../x'; name_from_the_root='/plan/x'
for unsafe_name in "$name_with_a_shell_character" "$name_git_reads_as_an_option" "$name_with_a_space" \
  "$name_climbing_a_level" "$name_from_the_root"; do
  unsafe="$(new_task "Odd plan $unsafe_name" "" "base: $unsafe_name
$body")"
  "$P/scripts/next.sh" "$unsafe" >/dev/null 2>&1; unsafe_code=$?
  check "BaseLineOutsideTheSafeNames_ClaimsNoWorktree [$unsafe_name]: a base: name outside the safe set is refused, never claimed from the config base, so it cannot reach a brief or a git command" \
    '[ -z "$("$P/scripts/steward.sh" find "$unsafe")" ]'
  check "BaseLineOutsideTheSafeNames_NamedRunExitsWithThePassOverCode [$unsafe_name]: a refused base passes the item over like a missing one" \
    '[ "$unsafe_code" -eq 4 ]'
done

echo "base: a recorded base that is not a safe name is never handed on"
set_claim_base() { python3 -c 'import json,sys; p=sys.argv[1]; c=json.load(open(p)); c["base"]=sys.argv[2]; json.dump(c,open(p,"w"))' "$("$P/scripts/steward.sh" find "$1")/.flow/claim.json" "$2"; }
loose_wt="$("$P/scripts/steward.sh" find "$loose")"
printf 'loose\n' > "$loose_wt/loose.txt" && git -C "$loose_wt" add loose.txt && git -C "$loose_wt" commit -qm loose
set_claim_base "$loose" "$name_git_reads_as_an_option"
rm -f "$(run_file "$loose")"
"$P/scripts/next.sh" "$loose" --json > "$work/tampered.json" 2>/dev/null
check "TamperedClaimBase_JsonBaseIsTheConfigBase: next.sh checks the name claim.json records and falls back to the config base, so a bad name never reaches the runner or git" \
  '[ "$(jget base < "$work/tampered.json")" = main ]'
set_claim_base "$loose" "$name_git_reads_as_an_option"
(cd "$loose_wt" && "$P/scripts/verify.sh" "$loose" >/dev/null 2>&1)
check "TamperedClaimBase_VerifyDiffsAgainstTheConfigBase: verify.sh checks the name claim.json records and measures the item's own files from the config base" \
  '[ "$(jget changed_files < "$("$P/scripts/steward.sh" reports "$loose")/verify.json")" = "[\"loose.txt\"]" ]'

[ "$fails" -eq 0 ] && { echo "base: ok"; exit 0; }
echo "base: $fails failed"; exit 1
