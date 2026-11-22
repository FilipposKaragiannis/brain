#!/bin/sh
# gate-list.sh: gate list --json, the quiz through a fake gh, and digits that stay strings.
# Takes no argument. Exit 0 when every check passes, 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$P"
work="$(mktemp -d)"
. "$P/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$P"
trap 'sandbox_close $?' EXIT
. "$here/_flow_setup.sh"
. "$here/_github_fixture.sh"
. "$here/_jobs_fixture.sh"
. "$here/_worktree_helpers.sh"
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\nnotify:\n  desktop: false\n' > "$home2/config.yaml"
FLOW_HOME="$home2" "$P/jobs/next.sh" claude >/dev/null
echo "gate list --json"
mkdir -p "$work/gates" && cd "$work/gates" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init
git worktree add -q --detach ../app-wt-1 && git worktree add -q --detach ../app-wt-2
mkdir -p .flow/gates ../app-wt-1/.flow
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../app-wt-1\n  - ../app-wt-2\nnotify:\n  desktop: false\n' > .flow/config.yaml
printf '{"item":"local:task/7"}\n' > ../app-wt-1/.flow/claim.json
json_obj gate=ambiguity item=local:task/7 "message=Two choices.
1. Keep the old name? Recommended: yes, because callers depend on it.
2) Same for the tap
   and the depth pass?
   **Recommended:** the same,
   until a feel test says otherwise.
3. Anything else?
   Recommended reading is plan.md.
4. Split the type?
   - Recommended: no." time=2026-10-25T08:00:00Z host=claude > .flow/gates/local-task-7.json
json_obj gate=plan-approval item=local:task/3 "message=The plan is ready.
Read plan.md." time=2026-10-24T09:00:00Z host=shell > .flow/gates/local-task-3.json
check "gate list: the plain output is unchanged" [ "$("$P/scripts/gate.sh" list)" = "$(printf '2026-10-24T09:00:00Z\tlocal:task/3\tplan-approval\tThe plan is ready.\n2026-10-25T08:00:00Z\tlocal:task/7\tambiguity\tTwo choices.')" ]
"$P/scripts/gate.sh" list --bogus >/dev/null 2>&1; code=$?
check "gate list: an unknown flag exits 2" [ "$code" -eq 2 ]
"$P/scripts/gate.sh" list --json extra >/dev/null 2>&1; code=$?
check "gate list: an extra argument exits 2" [ "$code" -eq 2 ]
json_obj gate=escalation item=local:task/9 message=42 time=20261025 host=shell > .flow/gates/local-task-9.json
cp .flow/gates/local-task-9.json "$work/gates/42.json"
printf '{"gate":"merge","message":"Merge it.","time":"2026-10-25T07:00:00Z"}\n' > .flow/gates/no-item.json
printf 'not json\n' > .flow/gates/broken.json
gj="$(FLOW_NOW=2026-10-25T09:00:00Z "$P/scripts/gate.sh" list --json 2>"$work/gates/err")"; code=$?
gq() { printf '%s' "$gj" | jget "$1"; }
check "gate json: exits 0 past a broken record" [ "$code" -eq 0 ]
check "gate json: a broken record is named on stderr" grep -q 'broken.json' "$work/gates/err"
check "gate json: every valid record is listed" [ "$(printf '%s' "$gj" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = 4 ]
check "gate json: each gate has the fields the console reads" [ "$(printf '%s' "$gj" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)[2]))')" = "item,gate,message,time,host,worktree,age_seconds,questions,options,raised_by,answered_by,condition,footer" ]
check "gate json: oldest first" [ "$(printf '%s' "$gj" | python3 -c 'import json,sys; print(",".join(str(g["item"]) for g in json.load(sys.stdin)))')" = "local:task/3,None,local:task/7,local:task/9" ]
check "gate json: the age of a day-old gate is against FLOW_NOW" [ "$(gq 0.age_seconds)" = 86400 ]
check "gate json: the age of an hour-old gate is against FLOW_NOW" [ "$(gq 2.age_seconds)" = 3600 ]
check "gate json: the claimed pool worktree" [ "$(gq 2.worktree)" = "$(cd ../app-wt-1 && pwd -P)" ]
check "gate json: no claim, worktree null" [ "$(gq 0.worktree)" = null ]
check "gate json: no item, no worktree even beside a free one" [ "$(gq 1.worktree)" = null ]
check "gate json: a digits-only message is a string" [ "$(printf '%s' "$gj" | python3 -c 'import json,sys; print(json.load(sys.stdin)[3]["message"] == "42")')" = True ]
check "json_obj: a digits-only message is written as a string" [ "$(python3 -c 'import json,sys; print(repr(json.load(open(sys.argv[1]))["message"]))' "$work/gates/42.json")" = "'42'" ]
check "gate json: a time that is no ISO time has no age" [ "$(gq 3.age_seconds)" = null ]
check "gate json: one question per numbered line, dot or bracket" [ "$(printf '%s' "$gj" | python3 -c 'import json,sys; print(",".join(str(q["number"]) for q in json.load(sys.stdin)[2]["questions"]))')" = "1,2,3,4" ]
check "gate json: an inline Recommended ends the question" [ "$(gq 2.questions.0.text)" = "Keep the old name?" ]
check "gate json: an inline Recommended is the recommended answer" [ "$(gq 2.questions.0.recommended)" = "yes, because callers depend on it." ]
check "gate json: a following line joins the question" [ "$(gq 2.questions.1.text)" = "Same for the tap and the depth pass?" ]
check "gate json: a bold Recommended line, continued, is the recommended answer" [ "$(gq 2.questions.1.recommended)" = "the same, until a feel test says otherwise." ]
check "gate json: Recommended without a colon is prose" [ "$(gq 2.questions.2.text)" = "Anything else? Recommended reading is plan.md." ]
check "gate json: no Recommended line, recommended null" [ "$(gq 2.questions.2.recommended)" = null ]
check "gate json: a listed Recommended line is the recommended answer" [ "$(gq 2.questions.3.recommended)" = "no." ]
check "gate json: no numbered line, no questions" [ "$(gq 0.questions)" = "[]" ]
rm .flow/gates/*.json
check "gate json: nothing pending, an empty array" [ "$("$P/scripts/gate.sh" list --json)" = "[]" ]

echo "quiz: parse, grade, record and mark the draft ready (fake gh)"
mkdir -p "$work/quiz" && cd "$work/quiz" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init
git worktree add -q --detach ../q-wt-1
mkdir -p .flow && printf 'adapters:\n  default: local\nbase: main\ngithub:\n  repo: acme/widgets\npool:\n  - ../q-wt-1\nnotify:\n  desktop: false\n' > .flow/config.yaml
q1="$("$P/adapters/local/create.sh" task "Charge shot" --size M --body "Hold to power up.")"
"$P/adapters/local/link-pr.sh" "$q1" https://github.com/acme/widgets/pull/90
qreports="$("$P/scripts/steward.sh" reports "$q1")"
cat > "$qreports/quiz.md" <<'MD'
<!-- flow:quiz -->
## Quiz for local:task/1
1. What fires a shot now?
   a) A tap only
   b) A tap, or a release after a hold
   c) Only a release after a hold
   Because: a tap still fires a normal shot, and a release after a hold fires a charged one.
2. What happens when the hold
   passes 600 ms?
   a) The shot fires on its own b) The power caps at full c) The charge resets
   **Because:** the power is clamped at 1.0,
   so a longer hold adds nothing.
3. Why does the tap golden replay matter?
   a) It proves a tap still plays as before
   b) It proves the glow renders
<!-- answers: 1b 2b 3a -->
MD
"$P/scripts/quiz.sh" show "$q1" > "$work/quiz/show.json"; code=$?
qs() { jget "$1" < "$work/quiz/show.json"; }
check_all "quiz show: exits 0 and names the item" '[ "$code" -eq 0 ] && [ "$(qs item)" = "$q1" ]'
check_all "quiz show: the title and three questions" '[ "$(qs title)" = "Quiz for local:task/1" ] && [ "$(python3 -c "import json,sys; print(len(json.load(sys.stdin)[\"questions\"]))" < "$work/quiz/show.json")" = 3 ]'
check "quiz show: one choice per line" [ "$(qs questions.0.choices)" = '[{"key": "a", "text": "A tap only"}, {"key": "b", "text": "A tap, or a release after a hold"}, {"key": "c", "text": "Only a release after a hold"}]' ]
check_all "quiz show: choices sharing a line, a question over two lines" '[ "$(qs questions.1.text)" = "What happens when the hold passes 600 ms?" ] && [ "$(qs questions.1.choices.2.text)" = "The charge resets" ]'
check_all "quiz show: the answer key" '[ "$(qs questions.0.answer)" = b ] && [ "$(qs questions.2.answer)" = a ]'
check_all "quiz show: a Because line, bold or plain, continued" '[ "$(qs questions.0.because)" = "a tap still fires a normal shot, and a release after a hold fires a charged one." ] && [ "$(qs questions.1.because)" = "the power is clamped at 1.0, so a longer hold adds nothing." ]'
check "quiz show: no Because line, because null" [ "$(qs questions.2.because)" = null ]
check "quiz show: no result before an answer" [ "$(qs result)" = null ]
"$P/scripts/quiz.sh" show local:task/77 >/dev/null 2>&1; code=$?
check "quiz show: an item with no quiz exits 2" [ "$code" -eq 2 ]
"$P/scripts/quiz.sh" answer "$q1" >/dev/null 2>&1; code=$?
check "quiz answer: no answers exits 2" [ "$code" -eq 2 ]
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr']['isDraft']=True; json.dump(d,open(p,'w'))"
: > "$FAKE_GH_DIR/calls.log"
qout="$("$P/scripts/quiz.sh" answer "$q1" 1b 2a 3a)"; code=$?
check "quiz answer: a wrong answer fails, exit 0, 2 of 3 right" sh -c "[ $code -eq 0 ] && printf '%s' \"$qout\" | grep -q 'quiz failed on $q1: 2 of 3 right'"
check_all "quiz answer: the result is kept in the reports" '[ "$(jget passed < "$qreports/quiz.json")" = false ] && [ "$(jget results.1.given < "$qreports/quiz.json")" = a ] && [ "$(jget results.1.right < "$qreports/quiz.json")" = false ]'
check "quiz answer: a fail leaves the draft alone" sh -c "! grep -q 'pr ready' '$FAKE_GH_DIR/calls.log'"
check "quiz answer: one events.log line per answer" grep -q "	$q1	quiz	failed 2/3" .flow/events.log
qout="$("$P/scripts/quiz.sh" answer "$q1" b b a)"
check "quiz answer: letters in question order pass" sh -c "printf '%s' \"$qout\" | grep -q 'quiz passed on $q1: 3 of 3 right; PR https://github.com/acme/widgets/pull/90 marked ready for review'"
check "quiz answer: a pass marks the item's draft PR ready" sh -c "grep -q 'pr ready 90 -R acme/widgets' '$FAKE_GH_DIR/calls.log' && python3 -c \"import json; assert json.load(open('$FAKE_GH_DIR/issues.json'))['pr']['isDraft'] is False\""
check_all "quiz answer: the pass is kept and logged" '[ "$(jget passed < "$qreports/quiz.json")" = true ] && grep -q "	$q1	quiz	passed 3/3" .flow/events.log'
"$P/scripts/quiz.sh" show "$q1" > "$work/quiz/show.json"
check_all "quiz show: the last result rides along" '[ "$(qs result.passed)" = true ] && [ "$(qs result.given)" = "{\"1\": \"b\", \"2\": \"b\", \"3\": \"a\"}" ]'
q2="$("$P/adapters/local/create.sh" task "No PR yet" --size S --body x)"
q2reports="$("$P/scripts/steward.sh" reports "$q2")"; cp "$qreports/quiz.md" "$q2reports/quiz.md"
: > "$FAKE_GH_DIR/calls.log"
qout="$("$P/scripts/quiz.sh" answer "$q2" 1b 2b 3a)"
check "quiz answer: a pass with no PR records the pass and asks gh nothing" sh -c "printf '%s' \"$qout\" | grep -q 'quiz passed on $q2: 3 of 3 right\$' && ! grep -q 'pr ready' '$FAKE_GH_DIR/calls.log'"
"$P/adapters/local/link-pr.sh" "$q2" --help >/dev/null
: > "$FAKE_GH_DIR/calls.log"
qout="$("$P/scripts/quiz.sh" answer "$q2" 1b 2b 3a)"
check "quiz answer: a pr in the state that is not a number is not marked ready" sh -c "printf '%s' \"$qout\" | grep -q 'quiz passed on $q2: 3 of 3 right; .*not marked ready' && ! grep -q 'pr ready' '$FAKE_GH_DIR/calls.log'"

echo "digits stay strings, numbers stay numbers"
mkdir -p "$work/digits" && cd "$work/digits" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init
git worktree add -q --detach ../01
mkdir -p .flow && printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../01\nnotify:\n  desktop: false\n' > .flow/config.yaml
jtype() { python3 -c 'import json,sys; v=json.load(sys.stdin)
for k in sys.argv[1].split("."): v = v[int(k)] if k.isdigit() else v[k]
print(type(v).__name__, v)' "$1"; }
d1="$("$P/scripts/new.sh" task '0451' --size S --body x 2>/dev/null)"
dn="$(FLOW_RUN_PID=4242 "$P/scripts/next.sh" --json 2>/dev/null)"
check "next --json: a title of digits with a leading zero is the string" [ "$(printf '%s' "$dn" | jtype title)" = "str 0451" ]
check "next --json: the review depth is a string" [ "$(printf '%s' "$dn" | jtype depth)" = "str quick" ]
check "claim.json: a pool folder named 01 is the string" [ "$(jtype name < ../01/.flow/claim.json)" = "str 01" ]
check "the run record: pid is a number" [ "$(jtype pid < ".flow/runs/$(item_slug "$d1").json")" = "int 4242" ]
printf '{"status":"done","summary":"ok"}\n' > "$(jget reports < ".flow/runs/$(item_slug "$d1").json")/implement.json"
check "advance --json: attempts is a number" [ "$("$P/scripts/advance.sh" "$d1" --json 2>/dev/null | jtype attempts)" = "int 0" ]
"$P/scripts/steward.sh" release "$d1" --force >/dev/null 2>&1; rm -f .flow/runs/*.json
FLOW_RUN_PID=not-a-pid "$P/scripts/next.sh" --json >/dev/null 2>&1
check "the run record: a pid that is no number is left out, the record still parses" [ "$(python3 -c 'import json,sys; print("pid" in json.load(sys.stdin))' < ".flow/runs/$(item_slug "$d1").json")" = False ]
"$P/scripts/steward.sh" release "$d1" --force >/dev/null 2>&1; rm -f .flow/runs/*.json
FLOW_RUN_PID=0042 "$P/scripts/next.sh" --json >/dev/null 2>&1
check "the run record: a pid with leading zeros is the number without them, not octal" [ "$(jtype pid < ".flow/runs/$(item_slug "$d1").json")" = "int 42" ]
"$P/scripts/gate.sh" raise "$d1" escalation 007 >/dev/null 2>&1
check "a gate raised with the message 007: the record parses, the message the string" [ "$(jtype message < ".flow/gates/$(item_slug "$d1").json")" = "str 007" ]
check "gate list --json: the message 007 is the string" [ "$("$P/scripts/gate.sh" list --json | jtype 0.message)" = "str 007" ]
# Records from before 1.20.2: a digits message is a number, and one with a leading zero does not parse.
printf '{"gate":"merge","item":"local:task/98","message":42,"time":"2026-10-24T10:00:00Z","host":"shell"}\n' > .flow/gates/local-task-98.json
printf '{"gate":"merge","item":"local:task/99","message":007,"time":"2026-10-24T10:00:00Z","host":"shell"}\n' > .flow/gates/local-task-99.json
check_all "board: an old gate with a number message shows, an old one that does not parse is skipped" 'b="$("$P/scripts/board.sh")" && printf "%s" "$b" | grep -q "local:task/98 (.*): 42" && printf "%s" "$b" | grep -q "escalation\*\* on $d1" && ! printf "%s" "$b" | grep -q "local:task/99"'
rm -f .flow/gates/local-task-98.json .flow/gates/local-task-99.json
"$P/scripts/lesson.sh" other "$d1" 12345 >/dev/null
check "a lesson whose text is 12345 is the string" [ "$(tail -1 .flow/lessons.jsonl | jtype text)" = "str 12345" ]
mkdir -p "$work/nojq" && ln -sf "$(command -v python3)" "$work/nojq/python3"
nojq="$(PATH="$work/nojq"; json_obj "d=$(printf 'a\377b')" n:=1)"
check "json_obj without jq: bytes that are not UTF-8 are replaced and the object parses" [ "$(printf '%s' "$nojq" | python3 -c 'import json,sys; print(json.load(sys.stdin)["d"] == "a\ufffdb")')" = True ]
check_all "runs.jsonl: seconds and exit are numbers on every line, result a string" '[ -s "$home2/log/runs.jsonl" ] && python3 -c "import json,sys
for l in open(sys.argv[1]):
    r = json.loads(l); assert type(r[\"seconds\"]) is int and type(r[\"exit\"]) is int and type(r[\"result\"]) is str, l" "$home2/log/runs.jsonl"'

[ "$fails" -eq 0 ] && { echo "gate-list: ok"; exit 0; }
echo "gate-list: $fails failed"; exit 1
