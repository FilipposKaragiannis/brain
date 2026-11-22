#!/bin/sh
# gate-input.sh: text that comes from an agent's result file never reaches a shell or an argument
# list as code, on the local adapter in throwaway repos with a stub osascript and a fake gh that
# records each argument. gate.sh raise refuses a gate profiles.json does not have, before it
# writes anything; notify.sh hands the notifier its title, subtitle and body as arguments; the
# GitHub adapter hands gh each label as one argument. No model runs.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

NOTIFIER_ARGUMENTS="$work/notifier-arguments.jsonl"
GH_ARGUMENTS="$work/gh-arguments.jsonl"
HOSTILE_TEXT='say "no" \ $(touch '"$work"'/pwned) `touch '"$work"'/pwned`'
export FAKE_GH_DIR="$work/gh"
mkdir -p "$FAKE_GH_DIR" "$work/stubs" && cp "$plugin/tests/_fake_gh.py" "$FAKE_GH_DIR/"
printf '#!/bin/sh\npython3 -c '"'"'import json, sys; print(json.dumps(sys.argv[1:]))'"'"' "$@" >> "%s"\n' "$NOTIFIER_ARGUMENTS" > "$work/stubs/osascript"
printf '#!/bin/sh\npython3 -c '"'"'import json, sys; print(json.dumps(sys.argv[1:]))'"'"' "$@" >> "%s"\nexec sh "%s" "$@"\n' "$GH_ARGUMENTS" "$plugin/tests/fake-gh.sh" > "$work/stubs/gh"
chmod +x "$work/stubs/osascript" "$work/stubs/gh"
PATH="$work/stubs:$PATH"; export PATH

# notifier_argument <n>: the nth argument from the end of the last osascript call.
notifier_argument() { tail -n 1 "$NOTIFIER_ARGUMENTS" | python3 -c 'import json, sys; print(json.load(sys.stdin)[-int(sys.argv[1])])' "$1"; }
# label_added_as_one_argument <label>: true when a gh call passed the label right after --add-label.
label_added_as_one_argument() {
  python3 -c 'import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
sys.exit(0 if any("--add-label" in call and sys.argv[2] in call[call.index("--add-label") + 1:][::2] for call in calls) else 1)' "$GH_ARGUMENTS" "$1"
}

echo "gate input: a gate profiles.json does not have"
new_repo unknown
sed -i.bak 's/desktop: false/desktop: true/' .flow/config.yaml && rm -f .flow/config.yaml.bak
unknown_item="$(new_task "Unknown gate")"
"$plugin/scripts/gate.sh" raise "$unknown_item" 'merge $(touch pwned)' "Merge it." > "$work/unknown.out" 2> "$work/unknown.err"; unknown_code=$?
check "UnknownGate_IsRefusedWithAUsageExit: the owner sees a clear stop, not a raised gate" \
  '[ "$unknown_code" -eq 2 ] && grep -q "unknown gate" "$work/unknown.err"'
check "UnknownGate_NamesTheGatesThatExist: the message says what to use instead" \
  'grep -q "plan-approval" "$work/unknown.err"'
check "UnknownGate_WritesNoGateRecord: nothing waits for an answer" \
  '[ ! -e .flow/gates ] && [ ! -e .flow/events.log ]'
check "UnknownGate_LeavesTheItemsGateAlone: the tracker holds no gate" \
  '[ "$(state "$unknown_item" gate)" = none ]'
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

echo "gate input: a label with a space"
new_repo labels
printf 'github:\n  repo: acme/widgets\n' >> .flow/config.yaml
printf '{"issues": [{"number": 1, "title": "Seed", "body": "", "state": "OPEN", "labels": [], "url": "https://gh/1", "blocked_by": [], "id": 1001, "node": "I_1"}]}' > "$FAKE_GH_DIR/issues.json"
labelled="$("$plugin/adapters/github/create.sh" task "Labelled" --body x)"
: > "$GH_ARGUMENTS"
"$plugin/adapters/github/write-state.sh" "$labelled" "worktree=/work/my project" step=plan > /dev/null 2>&1
check "LabelWithASpace_ReachesGhAsOneArgument: the path stays whole after --add-label" \
  'label_added_as_one_argument "wt:/work/my project"'

if [ "$fails" -eq 0 ]; then echo "gate-input: ok"; else echo "gate-input: $fails failed"; exit 1; fi
