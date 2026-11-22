#!/bin/sh
# gate-input.sh: text that comes from an agent's result file never reaches a shell or an argument
# list as code, on the local adapter in throwaway repos with stub notifiers that record each
# argument and the fake gh. gate.sh raise refuses a gate profiles.json does not have, before it
# writes anything; notify.sh hands the notifier its title, subtitle and body as arguments; the
# GitHub adapter hands gh each label as one argument. No model runs.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

NOTIFIER_ARGUMENTS="$work/notifier-arguments.jsonl"
NOTIFY_SEND_ARGUMENTS="$work/notify-send-arguments.jsonl"
HOSTILE_TEXT='say "no" \ $(touch '"$work"'/pwned) `touch '"$work"'/pwned`'
export FAKE_GH_DIR="$work/gh"
mkdir -p "$FAKE_GH_DIR" "$work/stubs" && cp "$plugin/tests/_fake_gh.py" "$FAKE_GH_DIR/"
printf '#!/bin/sh\npython3 -c '"'"'import json, sys; print(json.dumps(sys.argv[1:]))'"'"' "$@" >> "%s"\n' "$NOTIFIER_ARGUMENTS" > "$work/stubs/osascript"
printf '#!/bin/sh\npython3 -c '"'"'import json, sys; print(json.dumps(sys.argv[1:]))'"'"' "$@" >> "%s"\n' "$NOTIFY_SEND_ARGUMENTS" > "$work/stubs/notify-send"
ln -s "$plugin/tests/fake-gh.sh" "$work/stubs/gh"
chmod +x "$work/stubs/osascript" "$work/stubs/notify-send"
PATH="$work/stubs:$PATH"; export PATH

# notifier_argument <n>: the nth argument from the end of the last osascript call.
notifier_argument() { tail -n 1 "$NOTIFIER_ARGUMENTS" | python3 -c 'import json, sys; print(json.load(sys.stdin)[-int(sys.argv[1])])' "$1"; }
# notify_send_argument <n>: the nth argument from the end of the last notify-send call.
notify_send_argument() { tail -n 1 "$NOTIFY_SEND_ARGUMENTS" | python3 -c 'import json, sys; print(json.load(sys.stdin)[-int(sys.argv[1])])' "$1"; }
# issue_labels <number>: the labels the fake gh holds on the issue, one per line.
issue_labels() { gh issue view "$1" -R acme/widgets --json labels -q '.labels[].name'; }
# without_osascript: a PATH of the current one's tools with no osascript, so notify.sh takes its notify-send branch.
without_osascript() {
  mkdir -p "$work/linux" && ln -s "$work/stubs/notify-send" "$work/linux/notify-send"
  old_path="$PATH"; IFS=:
  for directory in $old_path; do
    for tool in "$directory"/*; do
      [ -e "$tool" ] || continue
      case "${tool##*/}" in osascript) ;; *) [ -e "$work/linux/${tool##*/}" ] || ln -s "$tool" "$work/linux/${tool##*/}" ;; esac
    done
  done
  unset IFS; printf '%s' "$work/linux"
}

echo "gate input: a gate profiles.json does not have"
new_repo unknown
sed -i.bak 's/desktop: false/desktop: true/' .flow/config.yaml && rm -f .flow/config.yaml.bak
unknown_item="$(new_task "Unknown gate")"
item_before="$("$local_adapter/read.sh" "$unknown_item")"
"$plugin/scripts/gate.sh" raise "$unknown_item" 'merge $(touch pwned)' "Merge it." > "$work/unknown.out" 2> "$work/unknown.err"; unknown_code=$?
check "UnknownGate_IsRefusedWithAUsageExit: the owner sees a clear stop, not a raised gate" \
  '[ "$unknown_code" -eq 2 ] && grep -q "unknown gate" "$work/unknown.err"'
check "UnknownGate_NamesTheGatesThatExist: the message says what to use instead" \
  'grep -q "plan-approval" "$work/unknown.err"'
check "UnknownGate_WritesNoGateRecord: nothing waits for an answer" \
  '[ ! -e .flow/gates ]'
check "UnknownGate_LogsNoGateEvent: the board shows nothing raised" \
  '[ ! -e .flow/events.log ]'
check "UnknownGate_LeavesTheItemsGateAlone: the tracker holds no gate" \
  '[ "$(state "$unknown_item" gate)" = none ]'
check "UnknownGate_WritesNoCommentOrState: the item reads as it did before" \
  '[ "$("$local_adapter/read.sh" "$unknown_item")" = "$item_before" ]'
check "UnknownGate_NotifiesNobody: no desktop notification went out" \
  '[ ! -e "$NOTIFIER_ARGUMENTS" ]'
check "UnknownGate_RunsNoShellText: the name's command substitution did not run" \
  '[ ! -e pwned ]'

echo "gate input: text with a quote, a backslash and a command substitution"
"$plugin/scripts/gate.sh" raise "$unknown_item" escalation "$HOSTILE_TEXT" > /dev/null 2>&1
check "GateMessage_ReachesTheNotifierBodyLiterally: the notifier receives it unchanged" \
  '[ "$(notifier_argument 3 | head -n 1)" = "$HOSTILE_TEXT" ]'
check "GateMessage_RunsNoShellText: no command in it ran" \
  '[ ! -e "$work/pwned" ]'
hostile_title="$(new_task "$HOSTILE_TEXT")"
"$plugin/scripts/gate.sh" raise "$hostile_title" ambiguity "Which one?" > /dev/null 2>&1
check "ItemTitle_ReachesTheNotifierSubtitleLiterally: the quote swap is gone" \
  '[ "$(notifier_argument 1)" = "$HOSTILE_TEXT" ]'
"$plugin/scripts/notify.sh" --event "$HOSTILE_TEXT" "Nothing ready." > /dev/null 2>&1
check "EventName_ReachesTheNotifierTitleLiterally: the title is no more code than the body" \
  '[ "$(notifier_argument 2)" = "flow: $HOSTILE_TEXT" ]'
PATH="$(without_osascript)" "$plugin/scripts/notify.sh" --event "$HOSTILE_TEXT" "$HOSTILE_TEXT" > /dev/null 2>&1
check "EventName_ReachesNotifySendTitleLiterally: the title is one argument after the end of options" \
  '[ "$(notify_send_argument 2)" = "flow: $HOSTILE_TEXT" ]'
check "EventMessage_ReachesNotifySendBodyLiterally: the body is one argument" \
  '[ "$(notify_send_argument 1)" = "$HOSTILE_TEXT" ]'
check "EventText_RunsNoShellText: no command in it ran on the notify-send branch" \
  '[ ! -e "$work/pwned" ]'

echo "gate input: a step result that names a gate profiles.json does not have"
new_repo advancing
advancing_item="$(new_task "Advancing")"
start_step "$advancing_item"
step_result "$advancing_item" "$(json_value step < "$(run_file "$advancing_item")")" '{"status": "gate", "gate": "merge $(touch pwned)", "message": "Which one?"}'
advancing_before="$("$local_adapter/read.sh" "$advancing_item")"
"$plugin/scripts/advance.sh" "$advancing_item" > "$work/advance.out" 2> "$work/advance.err"; advance_code=$?
check "ResultNamingAnUnknownGate_StopsAdvanceWithAUsageExit: the step does not report a gate that was never raised" \
  '[ "$advance_code" -eq 2 ] && grep -q "profiles.json does not have" "$work/advance.err"'
check "ResultNamingAnUnknownGate_WritesNoGateRecord: nothing waits for an answer" \
  '[ ! -e .flow/gates ]'
check "ResultNamingAnUnknownGate_LogsNoGateEvent: the board shows nothing raised" \
  '! grep -qs "Which one?" .flow/events.log'
check "ResultNamingAnUnknownGate_LeavesTheItemsGateAlone: the tracker holds no gate" \
  '[ "$(state "$advancing_item" gate)" = none ]'
check "ResultNamingAnUnknownGate_WritesNoCommentOrState: the item reads as it did before" \
  '[ "$("$local_adapter/read.sh" "$advancing_item")" = "$advancing_before" ]'
check "ResultNamingAnUnknownGate_WritesNoAskedFile: the step is not marked as having asked" \
  '[ ! -e .flow/asked ] || [ -z "$(ls .flow/asked)" ]'
check "ResultNamingAnUnknownGate_RunsNoShellText: the name's command substitution did not run" \
  '[ ! -e pwned ]'

echo "gate input: a sync step result that names a gate profiles.json does not have"
new_repo syncing
syncing_item="$(new_task "Syncing")"
start_step "$syncing_item"
python3 -c 'import json, sys; run = json.load(open(sys.argv[1])); run["step"] = "sync"; json.dump(run, open(sys.argv[1], "w"))' "$(run_file "$syncing_item")"
step_result "$syncing_item" sync '{"status": "gate", "gate": "merge $(touch pwned)", "message": "Which one?"}'
syncing_before="$("$local_adapter/read.sh" "$syncing_item")"
"$plugin/scripts/advance.sh" "$syncing_item" > "$work/sync.out" 2> "$work/sync.err"; sync_code=$?
check "SyncResultNamingAnUnknownGate_StopsAdvanceWithAUsageExit: the sync step does not report a gate that was never raised" \
  '[ "$sync_code" -eq 2 ] && grep -q "profiles.json does not have" "$work/sync.err"'
check "SyncResultNamingAnUnknownGate_WritesNoGateRecord: nothing waits for an answer" \
  '[ ! -e .flow/gates ]'
check "SyncResultNamingAnUnknownGate_WritesNoCommentOrState: the item reads as it did before" \
  '[ "$("$local_adapter/read.sh" "$syncing_item")" = "$syncing_before" ]'
check "SyncResultNamingAnUnknownGate_RunsNoShellText: the name's command substitution did not run" \
  '[ ! -e pwned ]'

echo "gate input: labels with a space and with a comma"
new_repo labels
printf 'github:\n  repo: acme/widgets\n' >> .flow/config.yaml
printf '{"issues": [{"number": 1, "title": "Seed", "body": "", "state": "OPEN", "labels": [], "url": "https://gh/1", "blocked_by": [], "id": 1001, "node": "I_1"}]}' > "$FAKE_GH_DIR/issues.json"
labelled="$("$plugin/adapters/github/create.sh" task "Labelled" --body x)"
"$plugin/adapters/github/write-state.sh" "$labelled" "worktree=/work/my project" step=plan > /dev/null 2>&1
check "LabelWithASpace_StaysWholeOnTheIssue: the path is one label" \
  'issue_labels 2 | grep -Fxq "wt:/work/my project"'
check "LabelWithASpace_LeavesNoLabelOfTheFirstWord: the path was not split" \
  '! issue_labels 2 | grep -Fxq "wt:/work/my"'
labels_before="$(issue_labels 2)"
"$plugin/adapters/github/write-state.sh" "$labelled" "worktree=a,b" > /dev/null 2> "$work/comma.err"; comma_code=$?
check "WorktreeWithAComma_IsRefusedWithAUsageExit: gh would read it as two labels" \
  '[ "$comma_code" -eq 2 ] && grep -q "comma" "$work/comma.err"'
check "WorktreeWithAComma_LeavesTheLabelsAlone: the issue holds what it held" \
  '[ "$(issue_labels 2)" = "$labels_before" ]'
gh issue edit 2 -R acme/widgets --add-label "step:x,gate:merge" > /dev/null
"$plugin/adapters/github/write-state.sh" "$labelled" step=review > /dev/null 2>&1
check "OldLabelWithAComma_IsLeftOnTheIssue: gh would remove it as two labels" \
  'issue_labels 2 | grep -Fxq "step:x,gate:merge"'
check "OldLabelWithoutAComma_IsStillRemoved: the stale step label goes" \
  '! issue_labels 2 | grep -Fxq "step:plan"'

if [ "$fails" -eq 0 ]; then echo "gate-input: ok"; else echo "gate-input: $fails failed"; exit 1; fi
