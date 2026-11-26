#!/bin/sh
# github-tracker.sh: the GitHub adapter's blips, fields, types and project, its tracker scope, readiness
# on every tracker, the comments plumbing, and review requests and chases, through a fake gh.
# Takes no argument. Exit 0 when every check passes, 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$P"
work="$(mktemp -d)"
. "$P/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$P"
trap 'sandbox_close $?' EXIT
. "$here/_flow_setup.sh"
. "$here/_github_fixture.sh"
"$P/adapters/github/write-state.sh" 'gh#10' step=design attempts=1 >/dev/null
echo "github blips (fake gh)"
# $FAKE_GH_DIR/fail makes the next N gh calls fail with a message; the waits are zero here.
export FLOW_GH_RETRY_WAIT="0 0"
printf '1\ngh: HTTP 502\napi graphql\n' > "$FAKE_GH_DIR/fail"
check_all "gh read survives one 502 and says so" '[ "$("$P/adapters/github/read.sh" "gh#10" 2>"$work/gh-err" | jget title)" = "Epic" ] && grep -q "flow: gh: gh: HTTP 502; trying again in 0s" "$work/gh-err"'
printf '1\ngh: HTTP 404: Not Found\napi graphql\n' > "$FAKE_GH_DIR/fail"
check_all "gh read: a 404 is final at once" '! "$P/adapters/github/read.sh" "gh#10" >/dev/null 2>"$work/gh-err" && ! grep -q "trying again" "$work/gh-err" && grep -q "cannot read gh#10" "$work/gh-err"'
printf '9\ngh: HTTP 504: 504 Gateway Timeout\napi graphql\n' > "$FAKE_GH_DIR/fail"; : > "$FAKE_GH_DIR/calls.log"
check_all "gh read: three 5xx end it with a word, not a traceback" '! "$P/adapters/github/read.sh" "gh#10" >/dev/null 2>"$work/gh-err" && grep -q "cannot read gh#10" "$work/gh-err" && ! grep -q Traceback "$work/gh-err" && [ "$(grep -c "^api graphql" "$FAKE_GH_DIR/calls.log")" -eq 3 ]'
printf '1\ngh: HTTP 503\n' > "$FAKE_GH_DIR/fail"
"$P/adapters/github/comment.sh" 'gh#10' --body "after the blip" 2>"$work/gh-err"
check_all "gh comment: a body from stdin survives a retry, once" 'grep -q "trying again" "$work/gh-err" && python3 -c "import json; cs=[c[\"body\"] for c in json.load(open(\"$FAKE_GH_DIR/issues.json\"))[\"issues\"][0].get(\"comments\",[])]; assert cs.count(\"after the blip\") == 1, cs"'
printf '1\ngh: HTTP 502\nissues/10/comments\n' > "$FAKE_GH_DIR/fail"
check_all "gh write-state: only the good try'\''s stdout is read (the 502 body is not)" '"$P/adapters/github/write-state.sh" "gh#10" step=design attempts=2 2>"$work/gh-err" && grep -q "trying again" "$work/gh-err" && [ "$("$P/adapters/github/read.sh" "gh#10" | jget state.attempts)" = "2" ]'
printf '3\ngh: HTTP 502\nissues/10/comments\n' > "$FAKE_GH_DIR/fail"
check_all "gh write-state: an unreadable state comment stops the write, so no second comment starts from nothing" '! "$P/adapters/github/write-state.sh" "gh#10" step=implement >/dev/null 2>"$work/gh-err" && grep -q "cannot read the comments of gh#10" "$work/gh-err"'
rm -f "$FAKE_GH_DIR/fail"
item="$("$P/adapters/github/read.sh" 'gh#10')"
check_all "gh write-state: the state before the blip stands, in one comment" '[ "$(printf '\''%s'\'' "$item" | jget state.step)" = "design" ] && [ "$(printf '\''%s'\'' "$item" | jget state.attempts)" = "2" ] && [ "$(python3 -c "import json; print(len([c for c in json.load(open(\"$FAKE_GH_DIR/issues.json\"))[\"issues\"][0][\"comments\"] if \"flow:state\" in c[\"body\"]]))")" = "1" ]'
printf '1\ngh: HTTP 502\nissues/12/comments -F\nlanded\n' > "$FAKE_GH_DIR/fail"
: > "$FAKE_GH_DIR/calls.log"
check_all "gh write-state: a first state comment whose answer was lost after it landed is found and patched, not made twice" '"$P/adapters/github/write-state.sh" "gh#12" step=design >/dev/null 2>"$work/gh-err" && [ "$("$P/adapters/github/read.sh" "gh#12" | jget state.step)" = "design" ] && [ "$(python3 -c "import json; print(len([c for c in json.load(open(\"$FAKE_GH_DIR/issues.json\"))[\"issues\"][2].get(\"comments\",[]) if \"flow:state\" in c[\"body\"]]))")" = "1" ] && grep -q "^api -X PATCH repos/acme/widgets/issues/comments/" "$FAKE_GH_DIR/calls.log"'
printf '1\ngh: HTTP 502\nissues/10/comments -F\n' > "$FAKE_GH_DIR/fail"
python3 -c "import json; d=json.load(open('$FAKE_GH_DIR/issues.json')); d['issues'][0]['comments']=[c for c in d['issues'][0].get('comments',[]) if 'flow:state' not in c['body']]; json.dump(d, open('$FAKE_GH_DIR/issues.json','w'))"
check_all "gh write-state: a first state comment that did not land is posted once more" '"$P/adapters/github/write-state.sh" "gh#10" step=plan >/dev/null 2>"$work/gh-err" && [ "$("$P/adapters/github/read.sh" "gh#10" | jget state.step)" = "plan" ] && [ "$(python3 -c "import json; print(len([c for c in json.load(open(\"$FAKE_GH_DIR/issues.json\"))[\"issues\"][0][\"comments\"] if \"flow:state\" in c[\"body\"]]))")" = "1" ]'
python3 -c "import json; d=json.load(open('$FAKE_GH_DIR/issues.json')); d['issues'][0]['comments']=[c for c in d['issues'][0]['comments'] if 'flow:state' not in c['body']]; json.dump(d, open('$FAKE_GH_DIR/issues.json','w'))"
printf '2\ngh: HTTP 502\nissues/10/comments -F\n' > "$FAKE_GH_DIR/fail"
check_all "gh write-state: a first state comment lost twice stops the write with a word" '! "$P/adapters/github/write-state.sh" "gh#10" step=plan >/dev/null 2>"$work/gh-err" && grep -q "cannot write the state of gh#10" "$work/gh-err" && [ "$(python3 -c "import json; print(len([c for c in json.load(open(\"$FAKE_GH_DIR/issues.json\"))[\"issues\"][0][\"comments\"] if \"flow:state\" in c[\"body\"]]))")" = "0" ]'
"$P/adapters/github/write-state.sh" 'gh#10' step=design attempts=2 >/dev/null 2>&1
printf '9\ngh: HTTP 502\nissue create\n' > "$FAKE_GH_DIR/fail"
check_all "gh create: an issue is made once, never on a second try" '! "$P/adapters/github/create.sh" task "Twice?" >/dev/null 2>"$work/gh-err" && ! grep -q "trying again" "$work/gh-err" && [ "$(grep -c "^issue create" "$FAKE_GH_DIR/calls.log")" -eq 1 ]'
rm -f "$FAKE_GH_DIR/fail"

printf '{"issues": [{"number": 20, "title": "Epic", "body": "", "state": "OPEN", "labels": ["epic"], "url": "https://gh/20", "id": 1020, "node": "I_20"}]}' > "$FAKE_GH_DIR/issues.json"
child="$("$P/adapters/github/create.sh" task "Slice one" --size S --parent 'gh#20' --body "## What
x")"
check "gh create returns id" [ "$child" = "gh#21" ]
check "gh create: sub-issue linked, size label, body tail" sh -c "grep -q 'addSubIssue' '$FAKE_GH_DIR/calls.log' && '$P/adapters/github/read.sh' 'gh#21' | grep -q '\"parent\": *\"gh#20\"' && '$P/adapters/github/read.sh' 'gh#21' | grep -q 'size:S'"
child2="$("$P/adapters/github/create.sh" task "Slice two" --blocked-by 'gh#21')"
check "gh create: blocker edge recorded" [ "$("$P/adapters/github/read.sh" "$child2" | jget blocked_by)" = '["gh#21"]' ]
check "gh parent from the body line in list" sh -c "'$P/adapters/github/list.sh' | grep -q '\"parent\": *\"gh#20\"'"

echo "github fields, types and project (fake gh)"
cp "$FAKE_GH_DIR/issues.json" "$work/issues.saved"; cp .flow/config.yaml "$work/config.saved"
cat > "$FAKE_GH_DIR/issues.json" <<'JSON'
{"issues": [
  {"number": 30, "title": "Epic", "state": "OPEN", "labels": [], "type": "Epic", "fields": {"Priority": "P1"}},
  {"number": 31, "title": "Feature", "body": "Parent: #30", "state": "OPEN", "labels": [], "type": "Feature", "fields": {"Size": "S", "Priority": "P2"}, "project_item": "PI_31", "project_status": "Ready"},
  {"number": 32, "title": "Bug", "state": "OPEN", "labels": [], "type": "Bug", "fields": {"Size": "M", "Priority": "P0"}, "url": "https://github.com/acme/widgets/issues/32"},
  {"number": 33, "title": "No priority", "state": "OPEN", "labels": [], "type": "Task", "fields": {"Size": "S"}},
  {"number": 34, "title": "No size", "state": "OPEN", "labels": [], "type": "Task", "fields": {"Priority": "P1"}},
  {"number": 35, "title": "Blocked", "state": "OPEN", "labels": [], "type": "Task", "fields": {"Size": "S", "Priority": "P3"}, "blocked_by": [33]},
  {"number": 36, "title": "Started", "state": "OPEN", "labels": ["step:implement"], "type": "Task", "fields": {"Size": "S", "Priority": "P2"}},
  {"number": 37, "title": "Asking", "state": "OPEN", "labels": ["gate:ambiguity"], "type": "Task", "fields": {"Size": "S", "Priority": "P2"}},
  {"number": 38, "title": "Merging", "state": "OPEN", "labels": ["gate:merge"], "type": "Task", "fields": {"Size": "S", "Priority": "P2"}},
  {"number": 39, "title": "Epic underway", "state": "OPEN", "labels": [], "type": "Epic", "fields": {"Priority": "P0"}},
  {"number": 40, "title": "Its task", "state": "OPEN", "labels": [], "type": "Task", "parent": 39, "fields": {"Priority": "P1"}}
]}
JSON
cat > .flow/config.yaml <<'YAML'
adapters:
  default: github
base: main
github:
  repo: acme/widgets
  types: true
  fields:
    size: Size
    priority: Priority
    area: Area
  project: 1
ready:
  priority_order: [P0, P1, P2, P3]
  needs: [priority, size]
pool:
  - ../wt-1
  - ../wt-2
notify:
  desktop: false
YAML
# gh#31 is a child of the epic gh#30: with the epic's branch in place it is judged on its fields alone.
git branch -q epic/30
"$P/adapters/github/list.sh" | python3 -c 'import json,sys; [print("%s %s %s %s %s" % (i["id"], i["kind"], i["size"] or "-", i["priority"] or "-", ",".join(i["needs"]) or "-")) for i in json.load(sys.stdin)]' > "$work/ghlist"
check "gh type picks the kind: Epic epic, Bug bug, Feature task" sh -c "'$P/adapters/github/list.sh' | python3 -c 'import json,sys; k={i[\"id\"]:i[\"kind\"] for i in json.load(sys.stdin)}; assert (k[\"gh#30\"],k[\"gh#32\"],k[\"gh#31\"])==(\"epic\",\"bug\",\"task\")'"
check "gh size and priority come from the issue fields" sh -c "'$P/adapters/github/read.sh' 'gh#32' | python3 -c 'import json,sys; i=json.load(sys.stdin); assert (i[\"size\"],i[\"priority\"],i[\"rank\"])==(\"M\",\"P0\",0)'"
check "gh a Parent: line with a colon names the parent" [ "$("$P/adapters/github/read.sh" 'gh#31' | jget parent)" = "gh#30" ]
check "gh an unstarted item lists the fields it lacks" sh -c "grep -qx 'gh#33 task S - priority' '$work/ghlist' && grep -qx 'gh#34 task - P1 size' '$work/ghlist'"
check "gh an epic needs no size" grep -qx 'gh#30 epic - P1 -' "$work/ghlist"
check "gh a started item needs nothing" grep -qx 'gh#36 task S P2 -' "$work/ghlist"
check "gh ready: missing fields, blockers, gates and open sub-issues are out; priority orders the rest" [ "$("$P/adapters/github/list-ready.sh" | python3 -c 'import json,sys; print(",".join(i["id"] for i in json.load(sys.stdin)))')" = "gh#32,gh#30,gh#31,gh#36" ]
check_all "graph: a GitHub epic's children come from the item list, native parent or Parent: line" '[ "$("$P/scripts/board.sh" --graph gh#39 | python3 -c "import json,sys; print(list(json.load(sys.stdin)[\"nodes\"]))")" = "['\''gh#40'\'']" ] && [ "$("$P/scripts/board.sh" --graph gh#30 | python3 -c "import json,sys; print(list(json.load(sys.stdin)[\"nodes\"]))")" = "['\''gh#31'\'']" ]'
sed -i.bak 's/^  priority_order: .*/  priority_order: [P2, P0, P1, P3]/' .flow/config.yaml
check_all "graph priorities: GitHub columns follow ready.priority_order, not the names" '[ "$("$P/scripts/board.sh" --graph priorities | python3 -c "import json,sys; print(\" \".join(c[\"priority\"] or \"-\" for c in json.load(sys.stdin)[\"columns\"]))")" = "P2 P0 P1 P3 -" ]'
mv .flow/config.yaml.bak .flow/config.yaml
printf '1\ngh: HTTP 401: Bad credentials\napi graphql\n' > "$FAKE_GH_DIR/fail"
check_all "graph: a failed adapter list stops the graph and shows the error" '! "$P/scripts/board.sh" --graph gh#39 >/dev/null 2>"$work/graph.err" && grep -q "Bad credentials" "$work/graph.err" && grep -q "no graph" "$work/graph.err" && ! grep -q "not an open item" "$work/graph.err"'
cp .flow/config.yaml .flow/config.yaml.bak && awk '{ print } /^  project: 1$/ { print "  limit: 3" }' .flow/config.yaml.bak > .flow/config.yaml
check_all "graph: a GitHub list cut at github.limit stops the graph and says so" '! "$P/scripts/board.sh" --graph priorities >"$work/graph.out" 2>"$work/graph.err" && [ ! -s "$work/graph.out" ] && grep -q "stopped at github.limit 3" "$work/graph.err" && grep -q "no graph" "$work/graph.err"'
mv .flow/config.yaml.bak .flow/config.yaml
check "gh list pages through every issue" [ "$(FLOW_GH_PAGE=2 "$P/adapters/github/list.sh" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = "11" ]
check "gh list stops at the limit and says so" sh -c "[ \"\$('$P/adapters/github/list.sh' --limit 3 2>'$work/limit.err' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')\" = 3 ] && grep -q 'github.limit 3' '$work/limit.err'"
printf '1\ngh: HTTP 502\n' > "$FAKE_GH_DIR/fail"
python3 -I "$P/adapters/github/_mutate.py" field acme/widgets 36 Size M 2>"$work/gh-err"
check_all "gh field write survives one 502" '[ "$(python3 -c "import json; print(next(i[\"fields\"].get(\"Size\",\"\") for i in json.load(open(\"$FAKE_GH_DIR/issues.json\"))[\"issues\"] if i[\"number\"]==36))")" = "M" ] && grep -q "trying again" "$work/gh-err"'
rm -f "$FAKE_GH_DIR/fail"
: > "$FAKE_GH_DIR/calls.log"
# card_history <number>: every Status the fake gh's project has held on the issue's card, oldest first.
card_history() { python3 -c 'import json,sys
stored = next(issue for issue in json.load(open(sys.argv[1]))["issues"] if issue["number"] == int(sys.argv[2]))
print(json.dumps(stored.get("project_status_history", [])))' "$FAKE_GH_DIR/issues.json" "$1"; }
history_before="$(card_history 33)"
"$P/adapters/github/write-state.sh" 'gh#33' size=L gate=ambiguity
check "gh write-state: size goes to the field, not a label" sh -c "[ \"\$('$P/adapters/github/read.sh' 'gh#33' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"size\"])')\" = L ] && ! grep -q 'size:L' '$FAKE_GH_DIR/calls.log'"
check "WriteStateOfAGate_LeavesTheCard: a gate label written to the tracker leaves the card's Status history as it was, because the card follows the flow record through set-status" [ "$(card_history 33)" = "$history_before" ]
cp .flow/config.yaml "$work/config.mirrored" && printf 'tracker_state: labels\n' >> .flow/config.yaml
sh -c '. "$FLOW_PLUGIN/lib/flow.sh" && take_item "gh#34"' >/dev/null 2>&1
history_before="$(card_history 34)"
"$P/scripts/gate.sh" raise 'gh#34' ambiguity "Which way?" implement >/dev/null 2>&1
check "GateRaiseWithLabelsAndProject_WritesTheCardOnce: a gate raised on a claimed item adds one Status to its card's history, because the push moves the card and the label write leaves it" [ "$(card_history 34 | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" -eq "$(printf '%s' "$history_before" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)) + 1)')" ]
mv "$work/config.mirrored" .flow/config.yaml
chore="$("$P/scripts/new.sh" task "Tidy" --size M --type Chore --body "## Acceptance
- x")"
check "gh create: --type sets the type, the size goes to the field, no labels" sh -c "'$P/adapters/github/read.sh' '$chore' | python3 -c 'import json,sys; i=json.load(sys.stdin); assert (i[\"type\"],i[\"size\"],i[\"labels\"])==(\"Chore\",\"M\",[])'"
epic="$("$P/scripts/new.sh" epic "Big")"
check "gh create: an epic gets the Epic type, not the label" sh -c "'$P/adapters/github/read.sh' '$epic' | python3 -c 'import json,sys; i=json.load(sys.stdin); assert (i[\"type\"],i[\"kind\"],i[\"labels\"])==(\"Epic\",\"epic\",[])'"
bots="$("$P/scripts/new.sh" task "Bot thing" --area Bots)"
check "gh create: --area goes to the area field" sh -c "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); i=[x for x in d[\"issues\"] if x[\"number\"]==int(sys.argv[2])][0]; assert i[\"fields\"].get(\"Area\")==\"Bots\", i' '$FAKE_GH_DIR/issues.json' '${bots#gh#}'"
gpar="$("$P/scripts/new.sh" task "Parent with fields" --size M --priority P1 --area Bots)"
gkid="$("$P/scripts/new.sh" task "Kid" --size S --parent "$gpar" 2>/dev/null)"
check "gh create: a child takes the parent's priority and area fields" sh -c "'$P/adapters/github/read.sh' '$gkid' | python3 -c 'import json,sys; i=json.load(sys.stdin); assert (i[\"priority\"],i[\"area\"],i[\"parent\"])==(\"P1\",\"Bots\",\"$gpar\"), i'"
"$P/scripts/new.sh" task "Orphan kid" --size S --parent "$bots" > /dev/null 2> "$work/orphan.err"
check "gh create: a child left without the priority ready.needs asks for is said" grep -q 'has no priority and ready.needs asks for one' "$work/orphan.err"
check "gh vocabulary: the issue types and the area options" sh -c "'$P/adapters/github/vocabulary.sh' | python3 -c 'import json,sys; v=json.load(sys.stdin); assert \"Chore\" in v[\"types\"] and v[\"areas\"]==[\"Bots\",\"Debugging & Observability\"], v'"
picked="$("$P/scripts/next.sh" --json)"
check "gh next picks the highest priority" [ "$(printf '%s' "$picked" | jget item)" = "gh#32" ]
end_run 'gh#32'; "$P/scripts/steward.sh" release "$(printf '%s' "$picked" | jget worktree)" --force >/dev/null 2>&1
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); [i.update(state='CLOSED') for i in d['issues'] if i['number']==40]; json.dump(d,open(p,'w'))"
check "gh an epic is ready again once its sub-issues close" sh -c "'$P/adapters/github/list-ready.sh' | grep -q '\"gh#39\"'"
"$P/scripts/gate.sh" raise 'gh#37' ambiguity "1. Visual only?
   Recommended: yes." >/dev/null 2>&1
printf '/answer 1. no, let it touch the ball' | FAKE_GH_USER=stranger gh issue comment 37 -R acme/widgets --body-file - >/dev/null
printf 'thinking about it' | gh issue comment 37 -R acme/widgets --body-file - >/dev/null
owner_answer="1. no, keep it visual"
printf '/answer %s' "$owner_answer" | gh issue comment 37 -R acme/widgets --body-file - >/dev/null
check "AnsweredGate_PrintsItsId: answers prints the id of the gate an owner's /answer cleared, because the job logs each id it prints" [ "$("$P/adapters/github/answers.sh" 'gh#37')" = "gh#37" ]
check "AnsweredGate_ClearsTheGate: the record holds no gate after the owner's /answer, because the answer is what clears it" [ "$(record get 'gh#37' gate)" = none ]
check "AnsweredGate_TakesTheOwnersWords: the record's answer is the owner's /answer, not a stranger's, because only an owner's answer counts" [ "$(record get 'gh#37' answer)" = "$owner_answer" ]
check "AnsweredGate_NamesTheGateItAnswered: the record names the ambiguity gate as the one answered, because the brief says which gate the answer is to" [ "$(record get 'gh#37' answered)" = ambiguity ]
check "AnsweredGate_KeepsTheQuestion: the record keeps the question the answer is to, because the next brief carries both" sh -c "'$P/scripts/state.sh' get 'gh#37' asked | grep -q 'Visual only?'"
check "AnsweredComment_GetsAPlusOne: the owner's /answer comment gets a +1, because the reaction is the owner's receipt on GitHub" grep -q '"content": "+1"' "$FAKE_GH_DIR/issues.json"
check "AnsweredGate_SecondPassClearsNothing: a second answers pass on the cleared id prints nothing, because its record holds no gate" [ -z "$("$P/adapters/github/answers.sh" 'gh#37')" ]
picked="$("$P/scripts/next.sh" 'gh#37' --json)"; brief="$(printf '%s' "$picked" | jget brief)"
check "the next brief carries the owner's answer and the question" sh -c "grep -q \"The owner's answer to the last gate (ambiguity)\" '$brief' && grep -q 'Answer: 1. no, keep it visual' '$brief' && grep -q 'Visual only?' '$brief'"
end_run 'gh#37'; "$P/scripts/steward.sh" release "$(printf '%s' "$picked" | jget worktree)" --force >/dev/null 2>&1
mkdir -p "$work/slackbin" && printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done >> "%s/slack.log"\n' "$work" > "$work/slackbin/curl" && chmod +x "$work/slackbin/curl"
PATH="$work/slackbin:$PATH" FLOW_SLACK_WEBHOOK=https://hook.example "$P/scripts/notify.sh" ambiguity 'gh#32' "1. Visual only?
   Recommended: yes, hash-inert." >/dev/null
check "notify: a gate names the item by title and links it" grep -qF '*flow: ambiguity* on <https://github.com/acme/widgets/issues/32|gh#32 Bug>' "$work/slack.log"
check "notify: the questions keep their lines, the recommendation under each" sh -c "python3 -c 'import json,sys; t=[json.loads(l) for l in open(sys.argv[1]) if l.startswith(\"{\")][0][\"text\"]; assert \"\\n1. Visual only?\\n   Recommended: yes\" in t and \"comment \x60/answer\" in t' '$work/slack.log'"
slack_blocks() { python3 -c 'import json,sys; print(json.dumps([json.loads(l) for l in open(sys.argv[1]) if l.startswith("{")][0]["blocks"]))' "$work/slack.log"; }
check "notify: Slack numbers the questions" sh -c "printf '%s' '$(slack_blocks)' | python3 -c 'import json,sys; lists=json.load(sys.stdin)[1][\"elements\"]; assert lists[0][\"style\"]==\"ordered\", lists[0]'"
check "notify: Slack nests the recommendation under its question" sh -c "printf '%s' '$(slack_blocks)' | python3 -c 'import json,sys; lists=json.load(sys.stdin)[1][\"elements\"]; nested=[l for l in lists if l[\"indent\"]==1]; assert nested and \"Recommended\" in json.dumps(nested), lists'"
check "notify: Slack names the gate as code" sh -c "printf '%s' '$(slack_blocks)' | python3 -c 'import json,sys; head=json.load(sys.stdin)[0]; assert {\"type\":\"text\",\"text\":\"ambiguity\",\"style\":{\"code\":True}} in head[\"elements\"][0][\"elements\"], head'"
check "notify: Slack says how to answer" sh -c "printf '%s' '$(slack_blocks)' | grep -q '/answer'"
slack_long() { python3 -I "$P/scripts/_slack.py" t '' '' '' '' 'The branch flow/gh-310 is behind at 3a677d23 and OptionUtility still prices the giveaway under the floor for every weight. The test step cannot change production code; see gh#320.'; }
check "slack: a long line breaks into one bullet per sentence" sh -c "printf '%s' '$(slack_long)' | python3 -c 'import json,sys; bullets=json.load(sys.stdin)[\"blocks\"][1][\"elements\"][0][\"elements\"]; assert len(bullets)==2, bullets'"
check "slack: ids, commits, paths and code names read as code" sh -c "printf '%s' '$(slack_long)' | python3 -c 'import json,sys; d=json.load(sys.stdin); code=[e[\"text\"] for l in d[\"blocks\"][1][\"elements\"] for s in l[\"elements\"] for e in s[\"elements\"] if e.get(\"style\",{}).get(\"code\")]; assert code==[\"flow/gh-310\",\"3a677d23\",\"OptionUtility\",\"gh#320\"], code'"
slack_codes() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(" ".join(e["text"] for l in d["blocks"][1]["elements"] for e in l.get("elements", []) if e.get("style",{}).get("code")))'; }
check_all "slack: a Jira id reads as code, the full stop after it left out" '[ "$(python3 -I "$P/scripts/_slack.py" t "" "" "" "" "Blocked by jira:WID-7." | slack_codes)" = "jira:WID-7" ]'
check_all "slack: a gate on a Jira item says to answer on the issue, as its adapter reads /answer" 'python3 -I "$P/scripts/_slack.py" t "jira:WID-7 x" https://acme.atlassian.net/browse/WID-7 ambiguity jira:WID-7 m | grep -q "Answer on the issue"'
check_all "slack: a gate on a local item says to answer in a session, as its adapter has no answers" 'python3 -I "$P/scripts/_slack.py" t "local:task/3 x" https://example.test/3 ambiguity local:task/3 m | grep -q "Answer in a session"'
mkdir -p "$work/slackplugin/scripts" "$work/slackplugin/adapters/linear" && cp "$P/scripts/_slack.py" "$work/slackplugin/scripts/" && printf 'lin:\n' > "$work/slackplugin/adapters/linear/prefix"
check_all "slack: an id reads as code by the prefix file of any adapter folder, not a fixed list" '[ "$(python3 -I "$work/slackplugin/scripts/_slack.py" t "" "" "" "" "See lin:ENG-4 and gh#5" | slack_codes)" = "lin:ENG-4" ]'
check "slack: a link that is not https stays out of the fallback" sh -c "python3 -I '$P/scripts/_slack.py' t 'gh#1 x' 'javascript:x|<!channel>' ambiguity 'gh#1' m | python3 -c 'import json,sys; t=json.load(sys.stdin)[\"text\"]; assert \"javascript\" not in t and \"<!channel>\" not in t, t'"
echo "github tracker scope (fake gh)"
cp "$FAKE_GH_DIR/issues.json" "$work/scope-issues.saved"; cp .flow/config.yaml "$work/scope-config.saved"
python3 - "$FAKE_GH_DIR/issues.json" <<'PY2'
import json, sys
path = sys.argv[1]; data = json.load(open(path))
for taken_issue in data["issues"]:
    taken_issue["assignees"] = []
data["issues"] += [{"number": 50, "title": "Team A's, mine", "state": "OPEN", "labels": ["team-a"], "assignees": ["owner"]},
                   {"number": 51, "title": "Team B's", "state": "OPEN", "labels": ["team-b"]}]
json.dump(data, open(path, "w"))
PY2
gh_scope_config() { # gh_scope_config <the github.scope block's lines>
  printf 'adapters:\n  default: github\nbase: main\ngithub:\n  repo: acme/widgets\n  scope:\n%s\npool:\n  - ../wt-1\n  - ../wt-2\nnotify:\n  desktop: false\n' "$1" > .flow/config.yaml
}
gh_scope_ids() { "$P/adapters/github/list.sh" "$@" 2>/dev/null | python3 -c 'import json,sys; print(" ".join(i["id"] for i in json.load(sys.stdin)))'; }
gh_scope_config '    labels: [team-a]'
for scope_issue in 50 51; do
  "$P/scripts/gate.sh" raise "gh#$scope_issue" ambiguity "1. Which team?" >/dev/null 2>&1
  printf '/answer 1. this one' | gh issue comment "$scope_issue" -R acme/widgets --body-file - >/dev/null
done
scope_cleared="$("$P/adapters/github/answers.sh" 'gh#50' 'gh#51' 2>/dev/null)"
check "ScopedAnswers_GateInside_IsCleared: answers clears an answered gate on an issue github.scope matches, because answers reads the scoped issues" [ "$scope_cleared" = "gh#50" ]
check "ScopedAnswers_GateOutside_IsLeft: answers leaves an answered gate on an issue outside github.scope, because it reads the scoped list" [ "$(record get 'gh#51' gate)" = "ambiguity" ]
gh_scope_config '    assignee: me'
check "ScopedListAssigneeMe_KeepsOnlyTheGhUsers: assignee: me in github.scope keeps only the issues assigned to the gh user, because me stands for the gh user" [ "$(gh_scope_ids)" = "gh#50" ]
scope_limit=1
check "ScopedList_LimitCountsMatches: github.limit counts the issues the scope matches, because the scope goes to GitHub's search" [ "$(gh_scope_ids --limit "$scope_limit")" = "gh#50" ]
gh_scope_config '    status: [Nonesuch]'
check "ScopedList_StatusOfNoIssueState_ListsNothing: a github.scope status that names no issue state keeps no issue, though it sends GitHub no qualifier, because the scope is matched on every issue read" [ "$("$P/adapters/github/list.sh" 2>/dev/null)" = "[]" ]
python3 - "$FAKE_GH_DIR/issues.json" <<'PY2'
import json, sys
path = sys.argv[1]; data = json.load(open(path))
data["issues"] = [{"number": 60, "title": "Newest task", "state": "OPEN", "labels": ["team-c"], "type": "Task"},
                  {"number": 61, "title": "Newer epic", "state": "OPEN", "labels": ["team-c", "epic"]},
                  {"number": 62, "title": "Bug past them", "state": "OPEN", "labels": ["team-c"], "type": "Bug"}]
json.dump(data, open(path, "w"))
PY2
gh_scope_config '    kinds: [bug]'
check "KindScopedList_NewerIssuesOfOtherKinds_ListsScopedPastThem: a list under github.scope kinds keeps a bug past the newer issues github.limit 1 would hold, because the kinds are matched before the limit counts an issue" [ "$(gh_scope_ids --limit 1)" = "gh#62" ]
gh_scope_config '    labels: [team-c]
    kinds: [bug]'
check "KindScopedSearch_NewerIssuesOfOtherKinds_ListsScopedPastThem: a scoped search under github.scope kinds keeps a bug past the newer matches github.limit 1 would hold, because the kinds are matched before the limit counts an issue" [ "$(gh_scope_ids --limit 1)" = "gh#62" ]
cp "$work/scope-issues.saved" "$FAKE_GH_DIR/issues.json"; cp "$work/scope-config.saved" .flow/config.yaml

echo "trackers and readiness on every tracker (fake gh)"
mkdir -p "$work/trackers" && cd "$work/trackers" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t
printf 'hi\n' > README.md && printf '.flow/\n' > .gitignore && git add -A && git commit -qm init && mkdir -p .flow
tracked_config() { # tracked_config <trackers line> <ready block>: the GitHub fields fixture, new items to local
  printf 'adapters:\n  default: local\n%s\nbase: main\ngithub:\n  repo: acme/widgets\n  types: true\n  fields:\n    size: Size\n    priority: Priority\n%s\npool:\npool_max: 2\nnotify:\n  desktop: false\n' "$1" "$2" > .flow/config.yaml
}
tracked_config 'trackers: [github, local]' 'ready:
  needs: [priority, size]
  priority_order: [P0, P1, P2, P3]'
tq0="$("$P/adapters/local/create.sh" task "No priority" --size S)"
check "trackers: the board reads GitHub when trackers names it, beside a local default" sh -c "'$P/scripts/board.sh' --json | python3 -c 'import json,sys; ids=[i[\"id\"] for i in json.load(sys.stdin)[\"items\"]]; assert \"gh#32\" in ids and \"$tq0\" in ids, ids'"
check_all "trackers: a board whose trackers all read has no tracker errors" '[ "$("$P/scripts/board.sh" --json | jget tracker_errors)" = "[]" ]'
tracked_config 'trackers: [github, local, jira]' ''
env -u JIRA_API_TOKEN "$P/scripts/board.sh" --json > "$work/board-jira.json" 2>/dev/null
check_all "trackers: a tracker whose list fails is named in tracker_errors with its reason" '[ "$(jget tracker_errors.0.tracker < "$work/board-jira.json")" = jira ] && jget tracker_errors.0.message < "$work/board-jira.json" | grep -q "JIRA_API_TOKEN is not set"'
check_all "trackers: a failing tracker leaves the items of the others on the board" 'jget items < "$work/board-jira.json" | grep -q "\"gh#32\""'
check_all "trackers: the text board lists a tracker it could not read" 'env -u JIRA_API_TOKEN "$P/scripts/board.sh" 2>/dev/null | grep -q "^- jira (exit 1): flow: JIRA_API_TOKEN is not set"'
tracked_config 'trackers: [github, local]' 'ready:
  needs: [priority, size]
  priority_order: [P0, P1, P2, P3]'
picked="$("$P/scripts/next.sh" --json 2>/dev/null)"
check "trackers: next picks the most urgent ready item from every named tracker" [ "$(printf '%s' "$picked" | jget item)" = "gh#32" ]
end_run 'gh#32'; "$P/scripts/steward.sh" release "$(printf '%s' "$picked" | jget worktree)" --force >/dev/null 2>&1
record set 'gh#36' step=done >/dev/null 2>&1
check "trackers: health reads every named tracker" sh -c "'$P/scripts/steward.sh' health 2>/dev/null | grep -q 'gh#36: done (every step ran)'"
tracked_config 'trackers: [github, linear]' ''
"$P/scripts/board.sh" >/dev/null 2>"$work/trackers.err"; code=$?
check "trackers: a name with no adapter is refused (exit 2) with the adapters there are" sh -c "[ $code -eq 2 ] && grep -q 'trackers names linear, not an adapter; the adapters are github jira local' '$work/trackers.err'"
"$P/scripts/steward.sh" health --dry-run >/dev/null 2>"$work/trackers.err"; code=$?
check "trackers: health refuses (exit 2) a name with no adapter instead of reading no tracker" sh -c "[ $code -eq 2 ] && grep -q 'trackers names linear' '$work/trackers.err'"
mkdir -p "$work/trackers/bin" && printf '#!/bin/sh\nexit 0\n' > "$work/trackers/bin/claude" && chmod +x "$work/trackers/bin/claude"
PATH="$work/trackers/bin:$PATH" "$P/jobs/comments.sh" claude >/dev/null 2>"$work/trackers.err"; code=$?
check "trackers: the comments job refuses (exit 2) a name with no adapter instead of a quiet pass" sh -c "[ $code -eq 2 ] && grep -q 'trackers names linear' '$work/trackers.err'"
tracked_config 'trackers: [github]' ''
"$P/scripts/new.sh" task "Never read" >/dev/null 2>"$work/trackers.err"; code=$?
check "trackers: new refuses (exit 2) while new items go to a tracker trackers leaves out" sh -c "[ $code -eq 2 ] && grep -q 'adapters.default is local, which trackers leaves out' '$work/trackers.err'"
check "init: --check reports an adapters value trackers leaves out as a gap" sh -c "FLOW_PLUGIN='$P' '$P/skills/init/scripts/init.sh' --check | grep -q 'gap: .flow/config.yaml: adapters.default is local, which trackers leaves out'"
tracked_config '' 'ready:
  needs: [size]
  priority_order: [P1, P0]'
tq1="$("$P/adapters/local/create.sh" task "Low" --size S --priority P0)"
tq2="$("$P/adapters/local/create.sh" task "Urgent" --size S --priority P1)"
tq3="$("$P/adapters/local/create.sh" task "Unsized" --priority P1)"
local_ready() { "$P/adapters/local/list-ready.sh" | python3 -c 'import json,sys; print(" ".join(i["id"] for i in json.load(sys.stdin)))'; }
check_all "ready: a local item without a field ready.needs asks for is not ready" '[ -n "$(local_ready)" ] && case " $(local_ready) " in *" $tq3 "*) false ;; *) true ;; esac'
check "ready: a local item lists the ready.needs fields it lacks" [ "$("$P/adapters/local/read.sh" "$tq3" | jget needs)" = '["size"]' ]
check "ready: local list-ready follows ready.priority_order, items with no priority last" [ "$(local_ready)" = "$tq2 $tq1 $tq0" ]
tracked_config '' 'ready:
  needs: [priority]'
"$P/scripts/new.sh" task "Local kid" --size S --parent "$tq0" >/dev/null 2>"$work/trackers.err"
check "ready: a local child without the priority ready.needs asks for is said" grep -q 'has no priority and ready.needs asks for one' "$work/trackers.err"
tracked_config '' 'ready:
  needs: [priority, owner]'
"$P/adapters/local/list.sh" >/dev/null 2>"$work/trackers.err"; code=$?
check "ready: an unknown field in ready.needs is refused (exit 2) with the fields the flow knows" sh -c "[ $code -eq 2 ] && grep -q 'ready.needs knows priority and size, not owner' '$work/trackers.err'"
printf 'adapters:\n  default: local\ntrackers: [github, local]\nbase: main\ngithub:\n  repo: acme/widgets\n  types: true\n  fields:\n    size: Size\n    priority: Priority\n  ready_needs: [priority]\n  priority_order: [P1, P0]\npool:\npool_max: 2\nnotify:\n  desktop: false\n' > .flow/config.yaml
check "ready: github.ready_needs still applies, to the GitHub adapter too" [ "$("$P/adapters/github/read.sh" 'gh#33' 2>/dev/null | jget needs)" = '["priority"]' ]
check "ready: github.priority_order still orders the local items" [ "$(local_ready 2>/dev/null)" = "$tq2 $tq3 $tq1" ]
"$P/scripts/board.sh" >/dev/null 2>"$work/trackers.err"
check "ready: the deprecated github keys warn once a board run, naming the new keys" sh -c "[ \"\$(grep -c 'deprecated: set ready.needs and ready.priority_order' '$work/trackers.err')\" = 1 ]"
printf 'adapters:\n  default: local\nbase: main\nready:\n  needs:\n  priority_order: []\ngithub:\n  ready_needs: [priority]\n  priority_order: [P1, P0]\npool:\npool_max: 2\nnotify:\n  desktop: false\n' > .flow/config.yaml
tq4="$("$P/adapters/local/create.sh" task "Sized, no priority" --size S 2>/dev/null)"
check_all "ready: an empty ready.needs asks for nothing, over the deprecated github.ready_needs" 'case " $(local_ready 2>/dev/null) " in *" $tq4 "*) true ;; *) false ;; esac'
check "ready: an empty ready.priority_order ranks every priority alike, over the deprecated github.priority_order" [ "$("$P/adapters/local/read.sh" "$tq1" 2>/dev/null | jget rank)" = "$("$P/adapters/local/read.sh" "$tq2" 2>/dev/null | jget rank)" ]
cd "$repo"
cp "$work/issues.saved" "$FAKE_GH_DIR/issues.json"; cp "$work/config.saved" .flow/config.yaml

echo "comments plumbing (fake gh)"
python3 - "$FAKE_GH_DIR/issues.json" <<'PY2'
import json, sys
d = json.load(open(sys.argv[1]))
d["threads"] = [{"id": "T_1", "isResolved": False, "isOutdated": False, "path": "src/A.cs", "line": 3,
                 "comments": {"nodes": [{"databaseId": 501, "body": "Magic number here", "author": {"login": "codex"}, "createdAt": "t"}]}},
                {"id": "T_2", "isResolved": True, "isOutdated": False, "path": "src/B.cs", "line": 1,
                 "comments": {"nodes": [{"databaseId": 502, "body": "old", "author": {"login": "claude"}, "createdAt": "t"}]}}]
json.dump(d, open(sys.argv[1], "w"))
PY2
threads="$("$P/scripts/comments.sh" threads 90)"
check_all "threads: unresolved only, with ids" '[ "$(printf '\''%s'\'' "$threads" | jget 0.thread_id)" = "T_1" ] && [ "$(printf '\''%s'\'' "$threads" | python3 -c '\''import json,sys; print(len(json.load(sys.stdin)))'\'')" = "1" ]'
"$P/scripts/comments.sh" reply 90 501 "fixed in abc123"
"$P/scripts/comments.sh" resolve T_1
check "reply and resolve" sh -c "python3 -c \"import json; d=json.load(open('$FAKE_GH_DIR/issues.json')); t=d['threads'][0]; assert t['isResolved'] and 'abc123' in t['comments']['nodes'][1]['body']\""
check "state and ready" sh -c "'$P/scripts/comments.sh' state 90 | grep -q '\"isDraft\": *true' && '$P/scripts/comments.sh' ready 90 && '$P/scripts/comments.sh' state 90 | grep -q '\"isDraft\": *false'"
# The PR calls the evals make through the same fake (tools/eval-bin/gh): none open, then one.
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr']=None; json.dump(d,open(p,'w'))"
check "fake gh: no PR yet" sh -c "! gh pr view 1 -R acme/widgets >/dev/null 2>&1 && [ \"\$(gh pr list --head flow/x)\" = '[]' ]"
printf 'the body' | gh pr create --base main --head flow/x --title T --body-file - >/dev/null
gh pr comment 91 --body "@codex please review"
check "fake gh: pr create and comment" sh -c "gh pr view 91 | grep -q '\"headRefName\": \"flow/x\"' && gh pr list --head flow/x | grep -q 'the body' && gh pr view 91 | grep -q '@codex please review'"

echo "review requests and chases (fake gh)"
cp .flow/config.yaml "$work/config.reviews"
check "reviewers: codex and claude when reviews.reviewers is unset" [ "$("$P/scripts/comments.sh" reviewers | tr '\n' ' ')" = "codex claude " ]
printf 'reviews:\n  reviewers: [codex, copilot]\n  chase_after: 30m\n  max_chases: 1\n' >> .flow/config.yaml
check "reviewers: the config list, inline" [ "$("$P/scripts/comments.sh" reviewers | tr '\n' ' ')" = "codex copilot " ]
"$P/scripts/comments.sh" request-review 91 "please review the diff. @claude <!-- flow:chase codex -->" >/dev/null
. "$here/_review_fixture.sh"
check "request-review: codex gets one mention comment with the request marker" sh -c "python3 -c \"import json,sys; c=[b for b in json.loads(sys.argv[1]) if 'flow:review-request codex' in b]; assert len(c)==1 and c[0].startswith('@codex please review the diff.'), c\" '$(pr_field comments)'"
check "request-review: copilot is asked through the reviewers API" [ "$(pr_field reviewers)" = '["@copilot"]' ]
check "request-review: a reviewer not in the list is not asked" sh -c "! printf '%s' '$(pr_field comments)' | grep -q '@claude'"
check "request-review: the ask carries no chase marker" sh -c "! printf '%s' '$(pr_field comments)' | grep -q '<!-- flow:chase'"
"$P/scripts/comments.sh" request-review 91 "please review this PR." @octo-cat >/dev/null
check "request-review with a reviewer: that one is asked, even off the list" sh -c "python3 -c \"import json,sys; c=[b for b in json.loads(sys.argv[1]) if 'flow:review-request octo-cat' in b]; assert len(c)==1 and c[0].startswith('@octo-cat please review this PR.'), c\" '$(pr_field comments)'"
check "request-review with a reviewer: no one else is asked again" sh -c "python3 -c \"import json,sys; c=[b for b in json.loads(sys.argv[1]) if 'flow:review-request codex' in b]; assert len(c)==1, c\" '$(pr_field comments)'"
check "request-review with a reviewer: a bad name is refused" sh -c "'$P/scripts/comments.sh' request-review 91 'please review' 'bad name' 2>&1 >/dev/null | grep -q \"request-review: 'bad name' is not a reviewer name\""
cp "$work/config.reviews" .flow/config.yaml; printf 'reviews:\n  reviewers: [bad name]\n' >> .flow/config.yaml
check "reviewers: a name with a space is refused by name" sh -c "'$P/scripts/comments.sh' reviewers 2>&1 >/dev/null | grep -q \"'bad name' is not a reviewer name\""
cp "$work/config.reviews" .flow/config.yaml; printf 'reviews:\n  reviewers:\n    claude: [octo-cat]\n    codex:\n      - mona\n    default: [hubot]\n' >> .flow/config.yaml
check "reviewers --host claude: the claude list of the map" [ "$("$P/scripts/comments.sh" reviewers --host claude | tr '\n' ' ')" = "octo-cat " ]
check "reviewers --host codex: the codex list of the map, in block form" [ "$("$P/scripts/comments.sh" reviewers --host codex | tr '\n' ' ')" = "mona " ]
check "reviewers with no host: the default list of the map" [ "$("$P/scripts/comments.sh" reviewers | tr '\n' ' ')" = "hubot " ]
check "reviewers --host: a host other than claude or codex is refused" sh -c "! '$P/scripts/comments.sh' reviewers --host shell"
pr_as() { python3 -c "import json,sys; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr'].update(headRefName=sys.argv[1], body=sys.argv[2], comments=[]); json.dump(d, open(p,'w'))" "$1" "$2"; }
claude_footer="Adds the slide.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
pr_as flow/x "$claude_footer"; "$P/scripts/comments.sh" request-review 91 "please review" >/dev/null
check "request-review: a PR whose body says Claude wrote it asks the claude list" [ "$(asked)" = "octo-cat" ]
pr_as flow/x "Adds the slide.

https://chatgpt.com/codex/tasks/task_e_6a1f"; "$P/scripts/comments.sh" request-review 91 "please review" >/dev/null
check "request-review: a PR whose body says Codex wrote it asks the codex list" [ "$(asked)" = "mona" ]
pr_as flow/x "Adds the slide."; "$P/scripts/comments.sh" request-review 91 "please review" >/dev/null
check "request-review: a PR whose author host is unknown asks the default list" [ "$(asked)" = "hubot" ]
record set 'gh#21' pr=https://gh/pull/91 pr_host=codex >/dev/null
pr_as flow/gh-21 "$claude_footer"; "$P/scripts/comments.sh" request-review 91 "please review" >/dev/null
check "request-review: the pr_host of the item the branch names wins over the body" [ "$(asked)" = "mona" ]
templated_bug="$("$P/adapters/local/create.sh" bug "Stuck ball" --body x)"
templated_bug_worktree="$("$P/scripts/steward.sh" claim "$templated_bug" --branch bugfix/12-x 2>/dev/null)"
record set "$templated_bug" pr_host=codex >/dev/null
pr_as bugfix/12-x "$claude_footer"; "$P/scripts/comments.sh" request-review 91 "please review" >/dev/null
check_all "RequestReviewOfATemplatedHead_AsksThePrHostListOfTheItemItsClaimNames: the head bugfix/12-x maps to the local bug through its claim, so its codex pr_host wins over the Claude footer" '[ "$(asked)" = "mona" ]'
"$P/scripts/steward.sh" release "$templated_bug_worktree" --force >/dev/null 2>&1
cp "$work/config.reviews" .flow/config.yaml; printf 'reviews:\n  reviewers:\n    claude: [octo-cat]\n' >> .flow/config.yaml
check "reviewers --host codex: a map with no codex list and no default gets codex and claude" [ "$("$P/scripts/comments.sh" reviewers --host codex | tr '\n' ' ')" = "codex claude " ]
cp "$work/config.reviews" .flow/config.yaml; printf 'reviews:\n  reviewers: [octo-cat]\n' >> .flow/config.yaml
check "reviewers --host claude: a plain list is the list of every host" [ "$("$P/scripts/comments.sh" reviewers --host claude | tr '\n' ' ')" = "octo-cat " ]
cp "$work/config.reviews" .flow/config.yaml; printf 'reviews:\n  reviewers: [codex]\n  chase_after: 30m\n  max_chases: 1\n' >> .flow/config.yaml
seed 7200 running 0
check "reviews: a Codex summary still running is no answer" [ "$(answered)" = False ]
check "reviews: the wait counts from the request" sh -c "'$P/scripts/comments.sh' reviews 91 | grep -q '\"waiting\": 72[0-9][0-9], \"chases\": 0'"
seed 7200 running 0 reply "You have reached your Codex usage limit. Try again later."
check "reviews: a usage-limit reply is no answer" [ "$(answered)" = False ]
seed 7200 running 0 reply "No issues found."
check "reviews: a plain reply from the reviewer answers" [ "$(answered)" = True ]
check "reviews: a plain reply carries no cannot" sh -c "! '$P/scripts/comments.sh' reviews 91 | grep -q cannot"
seed 7200 running 0 reply "To use Codex here, create an environment for this repo.
More text."
check "reviews: a reply that it cannot review answers, and carries its first line as cannot" sh -c "[ '$(answered)' = True ] && '$P/scripts/comments.sh' reviews 91 | grep -q '\"cannot\": \"To use Codex here, create an environment for this repo.\"'"
seed 7200 running 0 lookalike
check "reviews: a person whose login holds the bot's name does not answer for it" [ "$(answered)" = False ]
seed 7200 completed 0
check "reviews: a finished Codex summary for the head answers" [ "$(answered)" = True ]
seed 7200 running 1
check "reviews: a +1 on the request answers" [ "$(answered)" = True ]
seed 7200 running 0
out="$("$P/scripts/comments.sh" chase 91)"; code=$?
check "chase: a silent reviewer past chase_after is asked again" sh -c "[ $code -eq 0 ] && printf '%s' '$out' | grep -q 'chased codex on #91: .*(chase 1 of 1)'"
check "chase: the chase uses the trigger phrase, the marker and the head commit" sh -c "python3 -c \"import json,sys; c=json.loads(sys.argv[1]); assert len(c)==1 and c[0].startswith('@codex review') and 'flow:chase codex' in c[0] and 'abc1234d ' in c[0], c\" '$(pr_field comments)'"
seed 1790 running 0
out="$("$P/scripts/comments.sh" chase 91)"; code=$?
check "chase: a request just under chase_after waits" sh -c "[ $code -eq 0 ] && [ -z '$out' ] && [ $(posted) = 0 ]"
seed 1810 running 0
out="$("$P/scripts/comments.sh" chase 91)"
check "chase: a request just over chase_after is chased" sh -c "printf '%s' '$out' | grep -q 'chased codex' && [ $(posted) = 1 ]"
cp "$work/config.reviews" .flow/config.yaml; printf 'reviews:\n  reviewers: [codex]\n  max_chases: 1\n' >> .flow/config.yaml
seed 3000 running 0
out="$("$P/scripts/comments.sh" chase 91 2>&1)"; code=$?
check "chase: an unset chase_after is the 1h default, silently: a request 50m old waits" sh -c "[ $code -eq 0 ] && [ -z '$out' ] && [ $(posted) = 0 ]"
seed 3700 running 0
out="$("$P/scripts/comments.sh" chase 91 2>&1)"; code=$?
check "chase: an unset chase_after is the 1h default: a request 62m old is chased" sh -c "[ $code -eq 0 ] && printf '%s' '$out' | grep -q 'chased codex on #91' && ! printf '%s' '$out' | grep -q chase_after && [ $(posted) = 1 ]"
cp "$work/config.reviews" .flow/config.yaml; printf 'reviews:\n  reviewers: [codex]\n  chase_after: 30m\n  max_chases: 1\n' >> .flow/config.yaml
seed 7200 running 0 chase
rm -rf .flow/reviews; : > .flow/events.log
first="$("$P/scripts/comments.sh" chase 91)"; second="$("$P/scripts/comments.sh" chase 91)"; code=$?
check "chase: past max_chases the owner is told" sh -c "printf '%s' '$first' | grep -q 'stalled codex on #91'"
check "chase: the owner is told once per request" sh -c "[ $code -eq 0 ] && [ -z '$second' ] && [ \"\$(grep -c '	review-stalled	' .flow/events.log)\" = 1 ]"
check "chase: past max_chases nothing is posted on the PR" [ "$(posted)" = 0 ]
cp "$work/config.reviews" .flow/config.yaml; printf 'reviews:\n  reviewers: [copilot]\n  chase_after: 30m\n  max_chases: 1\n' >> .flow/config.yaml
python3 - "$FAKE_GH_DIR/issues.json" <<'PY2'
import json, sys, time
p = sys.argv[1]; d = json.load(open(p)); pr = d["pr"]
pr["comments"], pr["reviewers"], pr["reviews"] = [], ["@copilot"], []
pr["timeline"] = [{"event": "review_requested", "requested_reviewer": {"login": "Copilot", "type": "Bot"},
                   "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 7200))}]
json.dump(d, open(p, "w"))
PY2
rm -rf .flow/reviews; : > .flow/events.log
check "chase: a silent Copilot is asked again through the reviewers API" sh -c "'$P/scripts/comments.sh' chase 91 | grep -q 'chased copilot on #91: .*(chase 1 of 1)'"
check "chase: a Copilot chase posts no comment" [ "$(posted)" = 0 ]
check "chase: a Copilot re-ask that left no timeline event still waits chase_after" [ -z "$("$P/scripts/comments.sh" chase 91)" ]
python3 -c "import time; p='.flow/reviews/91-copilot.chases'; r,c,_=open(p).read().split(); open(p,'w').write('%s %s %d\n' % (r, c, time.time() - 7200))"
check "chase: a Copilot re-ask that left no timeline event still counts toward max_chases" sh -c "'$P/scripts/comments.sh' chase 91 | grep -q 'stalled copilot on #91' && [ \"\$(grep -c '	review-stalled	' .flow/events.log)\" = 1 ]"
python3 -c "import json,time; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr']['reviews']=[{'user': {'login': 'copilot-pull-request-reviewer[bot]', 'type': 'Bot'}, 'submitted_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}]; json.dump(d, open(p,'w'))"
check "reviews: a Copilot review after the request answers" sh -c "'$P/scripts/comments.sh' reviews 91 | grep -q '\"reviewer\": \"copilot\".*\"answered\": true'"
cp "$work/config.reviews" .flow/config.yaml

echo "github state comment authors (fake gh)"
cp "$FAKE_GH_DIR/issues.json" "$work/issues.authors"; cp .flow/config.yaml "$work/config.authors"
state_marker="$(python3 -c 'import re, sys; print(re.search(r"^STATE_MARKER=\"(.*)\"$", open(sys.argv[1]).read(), re.M).group(1))' "$P/adapters/github/_gh.sh")"
gh_user="$(gh api user -q .login)"
forger=mallory; teammate=teammate
python3 - "$FAKE_GH_DIR/issues.json" "$state_marker" "$gh_user" "$forger" "$teammate" <<'PY'
import json, sys
path, marker, gh_user, forger, teammate = sys.argv[1:]
def state(login, comment_id, fields):
    return {"id": comment_id, "body": "%s\n```json\n%s\n```\n" % (marker, json.dumps(fields)), "user": {"login": login}}
def issue(number, labels, comments):
    return {"number": number, "title": "Authors %d" % number, "body": "", "state": "OPEN", "labels": labels,
            "url": "https://gh/%d" % number, "comments": comments}
json.dump({"issues": [
    issue(50, ["step:plan"], [state(forger, 5001, {"step": "pr", "profile": "task-S"})]),
    issue(51, ["step:plan"], [state(forger, 5101, {"profile": "task-S"}), state(gh_user, 5102, {"profile": "task-L"})]),
    issue(52, ["step:plan"], [state(teammate, 5201, {"profile": "task-M"})]),
    issue(53, [], []),
    issue(54, ["step:plan"], [dict(state(gh_user, 5401, {"profile": "task-S"}), body="> " + state(gh_user, 5401, {"profile": "task-S"})["body"])]),
]}, open(path, "w"))
PY
printf 'adapters:\n  default: github\nbase: main\ngithub:\n  repo: acme/widgets\nnotify:\n  desktop: false\n' > .flow/config.yaml
# authored_states <number> <login>: the state of each marker comment login wrote on the issue, one JSON line each.
authored_states() { python3 -c 'import json, re, sys
issue = [issue for issue in json.load(open(sys.argv[1]))["issues"] if issue["number"] == int(sys.argv[2])][0]
for comment in issue.get("comments", []):
    if comment["body"].startswith(sys.argv[4]) and (comment.get("user") or {}).get("login") == sys.argv[3]:
        print(json.dumps(json.loads(re.search(r"```json\n(.*?)\n```", comment["body"], re.S).group(1)), sort_keys=True))' \
  "$FAKE_GH_DIR/issues.json" "$1" "$2" "$state_marker"; }
marker_comment_count() { authored_states "$1" "$2" | grep -c .; }
listed_profile() { "$P/adapters/github/list.sh" | python3 -c 'import json, sys
print(next((item["state"]["profile"] for item in json.load(sys.stdin) if item["id"] == sys.argv[1]), "not listed"))' "$1"; }
listed_ids() { "$P/adapters/github/list.sh" 2>/dev/null | python3 -c 'import json, sys; print(" ".join(item["id"] for item in json.load(sys.stdin)))'; }
code_of() { "$@" >/dev/null 2>&1; echo $?; }
check "ReadOfAMarkerCommentByAnotherLogin_GivesNoProfile: a state comment the gh user did not write sets nothing, because anyone can comment on a public issue" \
  [ -z "$("$P/adapters/github/read.sh" 'gh#50' | jget state.profile)" ]
check "ListOfAMarkerCommentByAnotherLogin_GivesNoProfile: the list reads no state from a comment the gh user did not write, because anyone can comment on a public issue" \
  [ -z "$(listed_profile 'gh#50')" ]
check "ReadOfAReplyThatQuotesTheMarker_GivesNoProfile: a comment that quotes the marker is no state comment, because only one the flow wrote starts with it" \
  [ -z "$("$P/adapters/github/read.sh" 'gh#54' | jget state.profile)" ]
check "ReadPastAMarkerCommentByAnotherLogin_TakesTheGhUsersComment: a forged comment before the flow's own hides nothing, because the read keeps looking for a trusted one" \
  [ "$("$P/adapters/github/read.sh" 'gh#51' | jget state.profile)" = task-L ]
# shellcheck disable=SC2034 # the check's condition reads it
forged_state="$(authored_states 50 "$forger")"
"$P/adapters/github/write-state.sh" 'gh#50' attempts=3 >/dev/null 2>&1
check_all "WriteStateBesideOnlyAForgedComment_LeavesItAsItWas: the forged comment is not patched, because the flow writes only its own" \
  '[ -n "$forged_state" ] && [ "$(authored_states 50 "$forger")" = "$forged_state" ]'
check "WriteStateBesideOnlyAForgedComment_PostsItsOwn: the gh user's state comment now holds the write, because a forged one is no state comment" \
  [ "$(authored_states 50 "$gh_user" | jget attempts)" = 3 ]
"$P/adapters/github/write-state.sh" 'gh#51' attempts=4 >/dev/null 2>&1
check "WriteStatePastAForgedComment_PatchesTheTrustedOne: the gh user's comment after the forged one holds the write, because it is the issue's state comment" \
  [ "$(authored_states 51 "$gh_user" | jget attempts)" = 4 ]
check "WriteStatePastAForgedComment_PostsNoSecond: the issue keeps one state comment by the gh user, because the trusted one was found" \
  [ "$(marker_comment_count 51 "$gh_user")" = 1 ]
printf 'adapters:\n  default: github\nbase: main\ngithub:\n  repo: acme/widgets\n  answer_from: [%s]\nnotify:\n  desktop: false\n' "$teammate" > .flow/config.yaml
check "AnswerFromListingALogin_TrustsItsStateComment: a state comment by a login in github.answer_from is read, because a team lists every login its machines write under" \
  [ "$("$P/adapters/github/read.sh" 'gh#52' | jget state.profile)" = task-M ]
check "AnswerFromLeavingOutTheGhUser_IgnoresItsStateComment: the gh user's state comment is not read when github.answer_from leaves it out, because the list names everyone trusted" \
  [ -z "$("$P/adapters/github/read.sh" 'gh#51' | jget state.profile)" ]
write_state_code="$(code_of "$P/adapters/github/write-state.sh" 'gh#53' attempts=1)"
check "WriteStateWithTheGhUserOutsideAnswerFrom_Refuses: a first state comment the readers would ignore is refused, because the next write would post one more" \
  [ "$write_state_code" -ne 0 ]
check "WriteStateWithTheGhUserOutsideAnswerFrom_PostsNoComment: the issue gets no state comment, because the gh user's would be ignored" \
  [ "$(marker_comment_count 53 "$gh_user")" = 0 ]
printf 'adapters:\n  default: github\nbase: main\ngithub:\n  repo: acme/widgets\n  answer_from: [%s, %s]\nnotify:\n  desktop: false\n' "$teammate" "$gh_user" > .flow/config.yaml
"$P/adapters/github/write-state.sh" 'gh#52' attempts=5 >/dev/null 2>&1
check "WriteStateBesideATeammatesStateComment_PatchesIt: the teammate's comment holds the write, because a login github.answer_from lists writes the issue's state comment" \
  [ "$(authored_states 52 "$teammate" | jget attempts)" = 5 ]
check "WriteStateBesideATeammatesStateComment_PostsNoSecond: the gh user posts no state comment of its own, because a second one would split the state" \
  [ "$(marker_comment_count 52 "$gh_user")" = 0 ]
"$P/adapters/github/strip-state.sh" 'gh#52' >/dev/null 2>&1
check "StripStateOfATeammatesStateComment_DeletesIt: the teammate's state comment is gone, because a login github.answer_from lists wrote it for the flow" \
  [ "$(marker_comment_count 52 "$teammate")" = 0 ]
printf 'adapters:\n  default: github\nbase: main\ngithub:\n  repo: acme/widgets\nnotify:\n  desktop: false\n' > .flow/config.yaml
gh_user_lookups_failing=99
printf '%s\ngh: HTTP 401: Bad credentials\napi user\n' "$gh_user_lookups_failing" > "$FAKE_GH_DIR/fail"
check "ReadWithNoTrustedLogin_Stops: a read that cannot tell whose state comment counts fails, because no answer beats a wrong one" \
  [ "$(code_of "$P/adapters/github/read.sh" 'gh#51')" -ne 0 ]
# shellcheck disable=SC2034 # the check's condition reads it
ids_listed_without_login=" $(listed_ids) "
check_all "ListWithNoTrustedLogin_LeavesOutAnIssueWhoseCommentItReads: a labelled issue drops out of the list, because its state cannot be told" \
  'case "$ids_listed_without_login" in *" gh#51 "*) false ;; *) true ;; esac'
check_all "ListWithNoTrustedLogin_KeepsAnIssueWhoseCommentItSkips: an unlabelled issue still lists, because the list reads no comment for it" \
  'case "$ids_listed_without_login" in *" gh#53 "*) true ;; *) false ;; esac'
check "WriteStateWithNoTrustedLogin_Fails: a write that cannot tell whose state comment counts stops, because it would take none for no comment" \
  [ "$(code_of "$P/adapters/github/write-state.sh" 'gh#53' attempts=1)" -ne 0 ]
check "WriteStateWithNoTrustedLogin_PostsNoComment: the issue gets no state comment, because a second one beside the real one would split the state" \
  [ "$(marker_comment_count 53 "$gh_user")" = 0 ]
check "StripStateWithNoTrustedLogin_Fails: a strip that cannot tell whose state comment counts stops, because it deletes only the flow's own" \
  [ "$(code_of "$P/adapters/github/strip-state.sh" 'gh#51')" -ne 0 ]
check "StripStateWithNoTrustedLogin_KeepsTheStateComment: the gh user's state comment is still there, because the strip stopped before it" \
  [ "$(marker_comment_count 51 "$gh_user")" = 1 ]
rm -f "$FAKE_GH_DIR/fail"
cp "$work/issues.authors" "$FAKE_GH_DIR/issues.json"; cp "$work/config.authors" .flow/config.yaml

[ "$fails" -eq 0 ] && { echo "github-tracker: ok"; exit 0; }
echo "github-tracker: $fails failed"; exit 1
