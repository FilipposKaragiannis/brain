#!/bin/sh
# migrate.sh: how the work an older flow left on its trackers carries over to the flow records.
# The lazy seed of an unrecorded item, state.sh import and its dry run, --strip, a run that fails
# part way, and which tracker_state the mirror follows, on the local adapter with the state put
# there by write-state.sh as an older flow left it; then import --strip end to end on the GitHub
# fake. Messages and prefixes are read from scripts/_state_import.py and _state_schema.py.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_state_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
export FLOW_MACHINE=alpha
import_usage_refused=2
import_partly_failed=1
state_comments_written=1

item_path() { printf '.flow/items/%s.md' "${1#local:}"; }
frontmatter() { python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import _item
meta, _ = _item.parse(sys.argv[2]); print(meta.get(sys.argv[3], ""))' "$local_adapter" "$(item_path "$1")" "$2"; }
no_stripped_key_left() { python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import _item
meta, _ = _item.parse(sys.argv[2]); left = sorted(set(meta) & _item.STRIPPED_KEYS); print("\n".join(left)); sys.exit(1 if left else 0)' "$local_adapter" "$(item_path "$1")"; }
scripts_constant() { python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import _state_import, _state_schema
module, name = sys.argv[2].split("."); print(getattr({"import": _state_import, "schema": _state_schema}[module], name))' "$plugin/scripts" "$1"; }
has_record() { record_path="$(record path "$1")" && [ -f "$record_path" ]; }
has_no_record() { record_path="$(record path "$1")" && [ ! -f "$record_path" ]; }
stores_snapshot() { cat .flow/state/*.json .flow/items/*/*.md 2>/dev/null | cksum; }
said_would() { grep '^would ' "$1" | grep -qF -- " $2"; }
said_would_strip() { grep -qxF -- "would strip $2" "$1"; }
reports_import_of() { cut -d, -f1 "$1" | grep -qxF -- "import $2"; }
unclaimed_why="$(scripts_constant import.UNCLAIMED_WHY | sed 's/%s/wt-9/')"
unreadable_why="$(scripts_constant import.UNREADABLE_WHY)"
pushed_in_progress="$(scripts_constant schema.STATUS_IN_PROGRESS)"

echo "the lazy seed: an item an older flow started reads and seeds from its tracker"
new_repo seeds
tracker_state_is ""
lazy="$(new_task "Started by an older flow")"
"$local_adapter/write-state.sh" "$lazy" step=implement profile=task-S size=M worktree=wt-1
mkdir -p .flow/runs && printf '%s' "$run_record" | with_item "$lazy" > "$(run_file "$lazy")"
check "UnrecordedStartedItemWithNoTrackerStateLine_ReadsItsStep: because the tracker's state stands in until a record exists" \
  '[ "$(record read "$lazy" | json_value state.step)" = implement ]'
check "UnrecordedStartedItemWithNoTrackerStateLine_ListsItsRunFile: because a run from before the records still shows" \
  '[ "$(record list runs "$lazy" | json_value item)" = "$lazy" ]'
record set "$lazy" last_event=resumed >/dev/null 2>&1
check "FirstWriteWithNoTrackerStateLine_CopiesTheTrackerStep: because nothing in flight restarts" \
  '[ "$(record get "$lazy" step)" = implement ]'
check "FirstWriteWithNoTrackerStateLine_CopiesTheTrackerProfile: because the run keeps the profile it started on" \
  '[ "$(record get "$lazy" profile)" = task-S ]'
check "FirstWriteWithNoTrackerStateLine_LeavesTheSizeOut: because the tracker's size stays its own" \
  'size_read="$(record get "$lazy" size)" && [ -z "$size_read" ]'

echo "import: a record for every open item an older flow left state on"
new_repo imports
owner_name="$("$local_adapter/me.sh" | head -n 1)"
plain="$(new_task "Never started")"
unheld="$(new_task "Profile only")"
"$local_adapter/write-state.sh" "$unheld" profile=task-M
claimed="$(new_task "Worktree claimed here")"
"$local_adapter/write-state.sh" "$claimed" step=implement worktree=wt-1
mkdir -p ../wt-1/.flow && printf '{"item":"%s"}\n' "$claimed" > ../wt-1/.flow/claim.json
unclaimed="$(new_task "Worktree on another machine")"
"$local_adapter/write-state.sh" "$unclaimed" step=implement worktree=wt-9
epic="$("$local_adapter/create.sh" epic "Epic in flight" --size L)"
"$local_adapter/write-state.sh" "$epic" step=grill
closed="$(new_task "Closed")"
"$local_adapter/write-state.sh" "$closed" step=plan
"$local_adapter/close.sh" "$closed" >/dev/null
recorded="$(new_task "Recorded already")"
"$local_adapter/write-state.sh" "$recorded" step=review
record set "$recorded" last_event=recorded >/dev/null 2>&1
recorded_before="$(cat "$(record path "$recorded")")"

before_dry_run="$(stores_snapshot)"
record import --dry-run > "$work/dry-run.out" 2>&1; code=$?
check "ImportDryRun_ExitsZero: because a plan with nothing failing is done" '[ "$code" -eq 0 ]'
check "ImportDryRun_ChangesNoRecordAndNoItem: because a dry run only says what it would do" \
  '[ "$(stores_snapshot)" = "$before_dry_run" ]'
for candidate in "$unheld" "$claimed" "$epic"; do
  check "ImportDryRun_NamesTheItemItWouldImport ($candidate): because the owner sees the import before it runs" \
    'said_would "$work/dry-run.out" "$candidate"'
done
check "ImportDryRun_NamesTheItemItWouldSkip: because a skipped item is never silent" \
  'said_would "$work/dry-run.out" "$unclaimed: $unclaimed_why"'

record import > "$work/import.out" 2>&1; code=$?
check "Import_ExitsZero: because every list and record write landed" '[ "$code" -eq 0 ]'
for candidate in "$unheld" "$claimed" "$epic"; do
  check "ImportOfACandidate_RecordsIt ($candidate): because every open item with flow state carries over" \
    'has_record "$candidate"'
done
check "ImportOfAnItemWithNoTrackerState_RecordsNothing: because a never-started item has nothing to carry over" \
  'has_no_record "$plain"'
check "ImportOfAClosedItem_RecordsNothing: because only open items are listed" 'has_no_record "$closed"'
check "ImportOfARecordedItem_LeavesItsRecord: because a record wins once it exists" \
  '[ "$(cat "$(record path "$recorded")")" = "$recorded_before" ]'
check "ImportOfAnItemClaimedHere_HoldsItForThisMachine: because its worktree's claim.json is on this machine" \
  '[ "$(record get "$claimed" claim.machine)" = "$FLOW_MACHINE" ]'
check "ImportOfAnItemWhoseWorktreeIsNotHere_RecordsNothing: because another machine may hold its worktree" \
  'has_no_record "$unclaimed"'
check "ImportOfAnItemWhoseWorktreeIsNotHere_SaysWhy: because a skipped item is never silent" \
  'grep -qF -- "$unclaimed: $unclaimed_why" "$work/import.out"'
check "ImportOfAnEpicInFlight_HoldsItForThisMachine: because a started item with no worktree was started here" \
  '[ "$(record get "$epic" claim.machine)" = "$FLOW_MACHINE" ]'
check "ImportOfAnUnheldItem_ClaimsNoMachine: because an item with no step or worktree is not in flight" \
  'machine_read="$(record get "$unheld" claim.machine)" && [ -z "$machine_read" ]'
check "ImportOfAHeldItem_AssignsIt: because the item this machine holds is the owner's on the tracker" \
  '[ -n "$owner_name" ] && [ "$(frontmatter "$claimed" assignee)" = "$owner_name" ]'
check "ImportOfAHeldItem_PushesItsWorkflow: because the tracker's card follows the record" \
  '[ "$(frontmatter "$claimed" workflow)" = "$pushed_in_progress" ]'
before_second_run="$(stores_snapshot)"
record import > "$work/second.out" 2>&1
check "SecondImport_ChangesNoRecordAndNoItem: because the same call again is safe" \
  '[ "$(stores_snapshot)" = "$before_second_run" ]'
check "ImportWithoutStrip_NamesARecordedItemThatKeepsItsState: because --strip is what takes it off" \
  'grep -F -- "$claimed " "$work/second.out" | grep -qF -- "--strip"'

echo "import --strip: the flow state comes off the tracker of each item recorded here"
tracker_state_is labels
record import --strip > "$work/labels.out" 2>&1; code=$?
check "ImportStripUnderTrackerStateLabels_ExitsTwo: because the mirror would write the state back" \
  '[ "$code" -eq "$import_usage_refused" ]'
check "ImportStripUnderTrackerStateLabels_LeavesTheTrackerState: because a refused strip changes nothing" \
  '[ "$(frontmatter "$claimed" step)" = implement ]'
tracker_state_is ""
# shellcheck disable=SC2034 # the check's condition reads it
before_dry_run_strip="$(stores_snapshot)"
record import --dry-run --strip > "$work/dry-run-strip.out" 2>&1
check "ImportDryRunStrip_ChangesNoRecordAndNoItem: because a dry run only says what it would strip" \
  '[ "$(stores_snapshot)" = "$before_dry_run_strip" ]'
check "ImportDryRunStrip_NamesTheRecordedItemItWouldStrip: because the owner sees the strip before it runs" \
  'said_would_strip "$work/dry-run-strip.out" "$claimed"'
record import --strip > "$work/strip.out" 2>&1; code=$?
check "ImportStrip_ExitsZero: because every strip landed" '[ "$code" -eq 0 ]'
check "ImportStrip_TakesTheStateKeysOff: because the record holds them now" 'no_stripped_key_left "$claimed"'
check "ImportStrip_TakesTheStateKeysOffARecordedItem: because an item recorded before the import is recorded here too" \
  'no_stripped_key_left "$recorded"'
check "ImportStrip_KeepsTheSize: because the size is the item's own" '[ "$(frontmatter "$claimed" size)" = S ]'
check "ImportStrip_KeepsTheRecord: because the record is where the state lives now" '[ "$(record get "$claimed" step)" = implement ]'
check "ImportStripOfASkippedItem_LeavesItsState: because no record here holds that state" \
  '[ "$(frontmatter "$unclaimed" step)" = implement ]'

echo "import of tracker text holding a newline or a tab: one row per item, never one it carries"
new_repo injection
victim="$(new_task "Worktree on another machine")"
"$local_adapter/write-state.sh" "$victim" step=implement worktree=wt-9
injecting="$(new_task "Worktree that carries rows")"
injected_worktree="$(printf 'pool-9\nstrip\t%s\t\nimport\t%s\theld\nend' "$victim" "$victim")"
"$local_adapter/write-state.sh" "$injecting" step=plan "worktree=$injected_worktree"
skipped_items=2
record import --strip > "$work/injection.out" 2>&1
check "ImportOfAWorktreeHoldingANewline_SaysOneLinePerItem: because tracker text never becomes a row of its own" \
  '[ "$(wc -l < "$work/injection.out")" -eq "$skipped_items" ]'
check "ImportStripOfAWorktreeCarryingAStripRow_LeavesTheOtherItemsState: because only a record here lets a strip run" \
  '[ "$(frontmatter "$victim" step)" = implement ]'
check "ImportOfAWorktreeCarryingAHeldImportRow_LeavesTheOtherItemUnassigned: because only an import of the item itself takes it" \
  '[ -z "$(frontmatter "$victim" assignee)" ]'

echo "import of a local item whose id names another tracker's item: no record for that id"
new_repo foreign
foreign="$(new_task "Says it is a GitHub issue")"
"$local_adapter/write-state.sh" "$foreign" step=review
foreign_id=gh#5
python3 -c 'import re, sys
path = sys.argv[1]; text = open(path).read()
open(path, "w").write(re.sub(r"(?m)^id: .*$", "id: " + sys.argv[2], text, count=1))' "$(item_path "$foreign")" "$foreign_id"
misshaped="$(new_task "Id of no adapter's shape")"
"$local_adapter/write-state.sh" "$misshaped" step=review
shaped="$(new_task "Id of the local shape")"
"$local_adapter/write-state.sh" "$shaped" step=review
misshaped_id="local:task#5"
python3 -c 'import re, sys
path = sys.argv[1]; text = open(path).read()
open(path, "w").write(re.sub(r"(?m)^id: .*$", "id: " + sys.argv[2], text, count=1))' "$(item_path "$misshaped")" "$misshaped_id"
record import > "$work/foreign.out" 2>&1
check "ImportOfALocalItemWithAGithubId_RecordsNothingForThatId: because a tracker's list speaks only for its own items" \
  'has_no_record "$foreign_id"'
check "ImportBesideAnIdOfNoAdaptersShape_ReportsTheImportOfAnIdOfTheLocalShape: because a misshaped id drops only its own row" \
  'reports_import_of "$work/foreign.out" "$shaped"'
check "ImportOfAnIdOfNoAdaptersShape_ReportsNoImportOfIt: because only an id its adapter's slug.sed gives back reaches the tracker" \
  '! reports_import_of "$work/foreign.out" "$misshaped_id"'
check "ImportOfAnIdOfNoAdaptersShape_SeedsNoRecord: because an id that only shares another item's slug would plant that item's record" \
  '[ "$(ls .flow/state)" = "$(basename "$(record path "$shaped")")" ] || { ls .flow/state; false; }'

echo "import of an id that shares a real item's slug: the real item keeps its own state"
new_repo aliased
alias_item="$(new_task "Id that aliases the next item")"
"$local_adapter/write-state.sh" "$alias_item" step=implement
real_item="$(new_task "Item the alias shares a slug with")"
"$local_adapter/write-state.sh" "$real_item" step=review
alias_id="$(printf '%s' "$real_item" | tr '/' '#')"
python3 -c 'import re, sys
path = sys.argv[1]; text = open(path).read()
open(path, "w").write(re.sub(r"(?m)^id: .*$", "id: " + sys.argv[2], text, count=1))' "$(item_path "$alias_item")" "$alias_id"
record import --dry-run > "$work/aliased-dry-run.out" 2>&1
check "DryRunBesideAnIdThatAliasesAnItem_NamesTheItem: because a misshaped id drops only its own row" \
  'said_would "$work/aliased-dry-run.out" "$real_item"'
check "DryRunOfAnIdThatAliasesAnItem_DoesNotNameIt: because only an id its adapter's slug.sed gives back reaches the tracker" \
  '! said_would "$work/aliased-dry-run.out" "$alias_id"'
record import > "$work/aliased.out" 2>&1
check "ImportOfAnIdThatAliasesAnItem_RecordsTheItemsOwnStep: because a slug another id shares must not carry that id's state" \
  '[ "$(record get "$real_item" step)" = review ]'

echo "import under a locale that cannot spell a worktree: every row still comes out"
latin_locale=en_US.ISO8859-1
if locale -a 2>/dev/null | grep -qx "$latin_locale"; then
  new_repo latin
  unspelled="$(new_task "Worktree outside Latin-1")"
  "$local_adapter/write-state.sh" "$unspelled" step=implement "worktree=wt-€"
  spelled="$(new_task "Worktree claimed here")"
  "$local_adapter/write-state.sh" "$spelled" step=implement worktree=wt-1
  mkdir -p ../wt-1/.flow && printf '{"item":"%s"}\n' "$spelled" > ../wt-1/.flow/claim.json
  LC_ALL="$latin_locale" record import > "$work/latin.out" 2>&1; code=$?
  check "ImportUnderALatin1Locale_ExitsZero: because a worktree the locale cannot spell fails nothing" '[ "$code" -eq 0 ]'
  check "ImportUnderALatin1Locale_AssignsTheItemItImports: because the row of a worktree the locale cannot spell never stops the rows after it" \
    '[ "$(frontmatter "$spelled" assignee)" = "$owner_name" ]'
else
  echo "  skip no $latin_locale locale here, so no output can fail to spell a worktree"
fi

echo "import --strip with a record that does not parse: that item is skipped, the rest still runs"
new_repo unreadable
broken="$(new_task "Record does not parse")"
"$local_adapter/write-state.sh" "$broken" step=plan
mkdir -p .flow/state && printf 'not json\n' > "$(record path "$broken")"
cleanable="$(new_task "Strips cleanly")"
"$local_adapter/write-state.sh" "$cleanable" step=plan
record set "$cleanable" last_event=recorded >/dev/null 2>&1
record import --strip > "$work/unreadable.out" 2>&1; code=$?
check "ImportStripWithARecordThatDoesNotParse_ExitsOne: because part of the run failed" \
  '[ "$code" -eq "$import_partly_failed" ]'
check "ImportOfAnItemWhoseRecordDoesNotParse_SaysWhy: because a skipped item is never silent" \
  'grep -qF -- "$broken: $unreadable_why" "$work/unreadable.out"'
check "ImportStripOfAnItemWhoseRecordDoesNotParse_LeavesItsState: because the tracker holds its only readable state" \
  '[ "$(frontmatter "$broken" step)" = plan ]'
check "ImportStripWithARecordThatDoesNotParse_StillStripsTheNext: because one unreadable record does not stop the run" \
  'no_stripped_key_left "$cleanable"'

echo "import --strip that a tracker refuses for one item: the rest still runs"
root_user=0
if [ "$(id -u)" -eq "$root_user" ]; then
  echo "  skip run as root, a read-only item folder refuses no write, so no tracker refuses the strip"
else
  new_repo refusals
  refusing="$("$local_adapter/create.sh" bug "Tracker refuses the strip" --size S --body x)"
  "$local_adapter/write-state.sh" "$refusing" step=plan
  record set "$refusing" last_event=recorded >/dev/null 2>&1
  cleanable="$(new_task "Strips cleanly")"
  "$local_adapter/write-state.sh" "$cleanable" step=plan
  record set "$cleanable" last_event=recorded >/dev/null 2>&1
  refusing_folder="$(dirname "$(item_path "$refusing")")"
  close_with_the_folder_writable() { closing_status="$1"; chmod u+w "$refusing_folder"; sandbox_close "$closing_status"; }
  trap 'close_with_the_folder_writable $?' EXIT
  chmod a-w "$refusing_folder"
  record import --strip > "$work/refusals.out" 2>&1; code=$?
  chmod u+w "$refusing_folder"
  trap 'sandbox_close $?' EXIT
  check "ImportStripThatATrackerRefuses_ExitsOne: because part of the run failed" \
    '[ "$code" -eq "$import_partly_failed" ]'
  check "ImportStripThatATrackerRefuses_NamesTheRefusedItem: because a failed strip is never silent" \
    'grep "^flow: " "$work/refusals.out" | grep -qF -- "$refusing"'
  check "ImportStripThatATrackerRefuses_LeavesItsState: because the strip did not land" \
    '[ "$(frontmatter "$refusing" step)" = plan ]'
  check "ImportStripThatFailsForOneItem_StillStripsTheNext: because one refusal does not stop the run" \
    'no_stripped_key_left "$cleanable"'
fi

echo "the mirror: tracker_state switches the tracker write"
mirrored="$(new_task "Mirror")"
tracker_state_is labels
record set "$mirrored" step=verify >/dev/null 2>&1
check "TrackerStateLabels_TrackerTakesTheStateWrite: because labels keeps the mirror for an older flow" \
  '[ "$(tracker "$mirrored" step)" = verify ]'
tracker_state_is none
record set "$mirrored" step=review >/dev/null 2>&1
check "TrackerStateNone_TrackerKeepsItsState: because none writes the record only" '[ "$(tracker "$mirrored" step)" = verify ]'
tracker_state_is ""

echo "import --strip on GitHub: labels and the state comment go, the size label stays"
new_repo github
P="$plugin"; . "$here/_github_fixture.sh"
"$plugin/adapters/github/write-state.sh" gh#11 step=implement profile=task-S >/dev/null 2>&1
issue_has_label() { python3 -c 'import json, sys
issue = [issue for issue in json.load(open(sys.argv[1]))["issues"] if issue["number"] == int(sys.argv[2])][0]
sys.exit(0 if sys.argv[3] in issue["labels"] else 1)' "$FAKE_GH_DIR/issues.json" "$1" "$2"; }
flow_label_count() { python3 -B -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import _state_schema
issue = [issue for issue in json.load(open(sys.argv[2]))["issues"] if issue["number"] == int(sys.argv[3])][0]
print(sum(1 for label in issue["labels"] if label.startswith(_state_schema.FLOW_LABEL_PREFIXES)))' "$plugin/scripts" "$FAKE_GH_DIR/issues.json" "$1"; }
state_comment_count() { python3 -c 'import json, sys
issue = [issue for issue in json.load(open(sys.argv[1]))["issues"] if issue["number"] == int(sys.argv[2])][0]
print(sum(1 for comment in issue.get("comments", []) if "flow:state" in comment["body"]))' "$FAKE_GH_DIR/issues.json" "$1"; }
check "GithubWriteState_PutsTheStepLabelOnTheIssue: because the strip below needs a label to take off" \
  'issue_has_label 11 step:implement'
check "GithubWriteState_PutsTheStateCommentOnTheIssue: because the strip below needs a comment to delete" \
  '[ "$(state_comment_count 11)" = "$state_comments_written" ]'
"$plugin/adapters/github/write-state.sh" gh#12 attempts=1 "answer=keep the ball" >/dev/null 2>&1
check "GithubWriteStateOfAnswerAndAttempts_PutsNoFlowLabelOnTheIssue: because the import below must find the state in the comment alone" \
  '[ "$(flow_label_count 12)" = 0 ]'
check "GithubWriteStateOfAnswerAndAttempts_PutsTheStateCommentOnTheIssue: because the import below needs a comment to read" \
  '[ "$(state_comment_count 12)" = "$state_comments_written" ]'
state_marker="$(python3 -c 'import re, sys; print(re.search(r"^STATE_MARKER=\"(.*)\"$", open(sys.argv[1]).read(), re.M).group(1))' "$plugin/adapters/github/_gh.sh")"
gh_user="$(gh api user -q .login)"
forger=mallory
forged_only=15
forged_first=14
python3 - "$FAKE_GH_DIR/issues.json" "$state_marker" "$gh_user" "$forger" "$forged_first" "$forged_only" <<'PY'
import json, sys
path, marker, gh_user, forger, forged_first, forged_only = sys.argv[1:]
def state(login, comment_id, fields):
    return {"id": comment_id, "body": "%s\n```json\n%s\n```\n" % (marker, json.dumps(fields)), "user": {"login": login}}
def issue(number, comments):
    return {"number": number, "title": "Authors %d" % number, "body": "", "state": "OPEN", "labels": [],
            "url": "https://gh/%d" % number, "comments": comments}
data = json.load(open(path))
data["issues"] += [
    issue(int(forged_first), [state(forger, 1401, {"answer": "a forged answer"}), state(gh_user, 1402, {"answer": "the real answer"})]),
    issue(int(forged_only), [state(forger, 1501, {"step": "pr", "profile": "task-S"})]),
]
json.dump(data, open(path, "w"))
PY
authored_state_count() { python3 -c 'import json, sys
issue = [issue for issue in json.load(open(sys.argv[1]))["issues"] if issue["number"] == int(sys.argv[2])][0]
print(sum(1 for comment in issue.get("comments", []) if comment["body"].startswith(sys.argv[4]) and (comment.get("user") or {}).get("login") == sys.argv[3]))' \
  "$FAKE_GH_DIR/issues.json" "$1" "$2" "$state_marker"; }
record import --strip > "$work/github.out" 2>&1; code=$?
check "GithubImportStrip_ExitsZero: because the import and the strip landed" '[ "$code" -eq 0 ]'
check "GithubImportStrip_RecordsTheStep: because the import runs before the strip" '[ "$(record get gh#11 step)" = implement ]'
check "GithubImportStrip_TakesTheFlowLabelsOff: because the record holds the state now" '[ "$(flow_label_count 11)" = 0 ]'
check "GithubImportStrip_DeletesTheStateComment: because the record holds the state now" '[ "$(state_comment_count 11)" = 0 ]'
check "GithubImportStrip_KeepsTheSizeLabel: because the size is the issue's own" 'issue_has_label 11 size:S'
check "GithubImportOfAnIssueWithStateInItsCommentAlone_RecordsTheAnswer: because an unlabelled issue's comment is tracker state too" \
  '[ "$(record get gh#12 answer)" = "keep the ball" ]'
check "GithubImportStripOfAnIssueWithStateInItsCommentAlone_DeletesTheStateComment: because the record holds the state now" \
  '[ "$(state_comment_count 12)" = 0 ]'
check "GithubImportOfAForgedStateComment_RecordsNothing: because a state comment another login wrote is no state, so it cannot set a first start's step" \
  'has_no_record "gh#$forged_only"'
check "GithubImportPastAForgedStateComment_RecordsTheTrustedAnswer: because a forged comment first hides nothing from the import" \
  '[ "$(record get "gh#$forged_first" answer)" = "the real answer" ]'
check "GithubImportStripPastAForgedStateComment_DeletesTheTrustedOne: because the record holds the state now" \
  '[ "$(authored_state_count "$forged_first" "$gh_user")" = 0 ]'
check "GithubImportStripPastAForgedStateComment_KeepsTheForgedOne: because the flow deletes only the comments it wrote" \
  '[ "$(authored_state_count "$forged_first" "$forger")" = 1 ]'

[ "$fails" -eq 0 ] && { echo "migrate: ok"; exit 0; }
echo "migrate: $fails failed"; exit 1
