#!/bin/sh
# adapter-contract.sh <adapter>: the tracker contract of adapters/README.md, run against one
# adapter and its fake backend. Each adapter gets a setup below: setup_<name> puts its fake first
# on PATH, config_<name> <readiness 0|1> prints its own config block, missing_<name> an id it owns
# that names no item, comments_<name> <id> the comment texts the backend holds for an item, and
# blip_<name>, where the backend is a network, makes the next call fail with a 5xx. No check
# reaches the network. Exit 0 when every check passes, 1 on any failure, 2 on a bad argument.
set -u
[ $# -eq 1 ] || { echo "usage: adapter-contract.sh <adapter>" >&2; exit 2; }
name="$1"
here="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$P"
A="$P/adapters/$name"
[ -d "$A" ] || { echo "adapter-contract: no adapter $name under $P/adapters" >&2; exit 2; }
work="$(mktemp -d)"
. "$P/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$P"
trap 'sandbox_close $?' EXIT
export FLOW_HOME="$work/home"; mkdir -p "$FLOW_HOME" "$work/bin"
unset FLOW_TRACKER_STATE
for tool in gh curl osascript notify-send; do
  printf '#!/bin/sh\necho "adapter-contract: %s is offline here" >&2\nexit 1\n' "$tool" > "$work/bin/$tool"
  chmod +x "$work/bin/$tool"
done
PATH="$work/bin:$PATH"; export PATH
cd "$work" || exit 2
. "$P/lib/flow.sh"
ready_lib=0; type ready_rules >/dev/null 2>&1 && ready_lib=1

checks=0; fails=0
pass() { checks=$((checks + 1)); echo "  ok   $1"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); echo "  FAIL $1"; }
check() { # check <name> '<condition>': the condition is shell text, run whole
  if (eval "$2") >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi
}
skip() { echo "  skip $1"; }
jget() { python3 -c 'import json,sys; v=json.load(sys.stdin)
for k in sys.argv[1].split("."): v = v[int(k)] if k.isdigit() else v[k]
print(v if isinstance(v,str) else json.dumps(v))' "$1"; }
field() { "$A/read.sh" "$1" 2>/dev/null | jget "$2"; }
code_of() { "$@" >/dev/null 2>&1; echo $?; }
# listed <id> <script> [args]: the script's JSON array names the id.
listed() {
  li_id="$1"; shift
  "$@" 2>/dev/null | python3 -c 'import json,sys; sys.exit(0 if sys.argv[1] in [i["id"] for i in json.load(sys.stdin)] else 1)' "$li_id"
}
# before <first> <second> <script>: both are in the script's JSON array, the first one earlier.
before() {
  "$3" 2>/dev/null | python3 -c 'import json,sys; ids=[i["id"] for i in json.load(sys.stdin)]
sys.exit(0 if sys.argv[1] in ids and sys.argv[2] in ids and ids.index(sys.argv[1]) < ids.index(sys.argv[2]) else 1)' "$1" "$2"
}
# shape: the item JSON on stdin has every field of the contract with its type; prints what is off.
# rank and needs are required once lib/flow.sh has ready_rules.
shape() {
  python3 -c '
import json, sys
item = json.load(sys.stdin)
ITEM = {"id": str, "kind": str, "title": str, "body": str, "status": str, "size": str, "priority": str, "area": str,
        "labels": list, "blocked_by": list, "parent": str, "open_children": int, "url": str, "state": dict}
STATE = {"step": str, "profile": str, "size": str, "worktree": str, "attempts": int, "gate": str, "last_event": str,
         "pr": str, "touches": list}
OPTIONAL = {"rank": int, "needs": list, "open_blockers": list, "type": str}
if sys.argv[1] == "1":
    ITEM.update(rank=int, needs=list)
def off(where, data, spec, required):
    for key, kind in spec.items():
        if key not in data:
            if required: print("%s%s is missing" % (where, key))
        elif not isinstance(data[key], kind) or (kind is int and isinstance(data[key], bool)):
            print("%s%s is %r, not a %s" % (where, key, data[key], kind.__name__))
off("", item, ITEM, True); off("", item, OPTIONAL, False); off("state.", item.get("state") or {}, STATE, True)
if item.get("kind") not in ("epic", "task", "bug"): print("kind is %r" % item.get("kind"))
if item.get("status") not in ("open", "closed"): print("status is %r" % item.get("status"))
if not (item.get("state") or {}).get("gate"): print("state.gate is empty, not none")' "$ready_lib"
}

# --- the backends

setup_local() { :; }
config_local() { :; }
missing_local() { echo 'local:task/999'; }
comments_local() { sed -n '/^## Comments/,$p' "$FLOW_HOME/items/${1#local:}.md"; }

setup_github() {
  export FAKE_GH_DIR="$work/gh"; mkdir -p "$FAKE_GH_DIR"; cp "$here/_fake_gh.py" "$FAKE_GH_DIR/"
  printf '{"issues": [{"number": 1, "title": "Seed", "body": "", "state": "CLOSED", "labels": [], "url": "https://gh/1"}]}\n' > "$FAKE_GH_DIR/issues.json"
  ln -sf "$here/fake-gh.sh" "$work/bin/gh"
  export FLOW_GH_RETRY_WAIT="0 0"
}
# Without ready_rules in lib/flow.sh the GitHub adapter reads only its own older readiness keys.
config_github() {
  printf 'github:\n  repo: acme/widgets\n  fields:\n    priority: Priority\n    area: Area\n'
  [ "$1" = 1 ] && [ "$ready_lib" = 0 ] && printf '  ready_needs: [priority]\n  priority_order: [P0, P1, P2, P3]\n'
  return 0
}
missing_github() { echo 'gh#999'; }
comments_github() {
  python3 -c 'import json,sys; [print(c["body"]) for i in json.load(open(sys.argv[1]))["issues"] if i["number"] == int(sys.argv[2]) for c in i.get("comments", [])]' \
    "$FAKE_GH_DIR/issues.json" "${1#gh#}"
}
blip_github() { printf '1\ngh: HTTP 502\n' > "$FAKE_GH_DIR/fail"; }

setup_jira() {
  export FAKE_JIRA_DIR="$work/jira"; mkdir -p "$FAKE_JIRA_DIR"; cp "$here/_fake_jira.py" "$FAKE_JIRA_DIR/"
  printf '{}\n' > "$FAKE_JIRA_DIR/jira.json"
  ln -sf "$here/fake-jira.sh" "$work/bin/curl"
  export JIRA_API_TOKEN="contract-token" FLOW_JIRA_RETRY_WAIT="0 0"
}
config_jira() {
  printf 'jira:\n  site: https://acme.atlassian.net\n  project: WID\n  email: flow@acme.test\n  fields:\n    area: Area\n'
}
scope_config_jira() { printf '  scope:\n%s\n' "$1"; }
missing_jira() { echo 'jira:WID-999'; }
comments_jira() {
  python3 -c 'import json,sys
def text(node): return node.get("text", "") + "".join(text(c) for c in node.get("content", []))
[print(text(c["body"])) for c in json.load(open(sys.argv[1]))["issues"][sys.argv[2]]["comments"]]' "$FAKE_JIRA_DIR/jira.json" "${1#jira:}"
}
blip_jira() { printf '1\n503\n' > "$FAKE_JIRA_DIR/fail"; }

type "setup_$name" >/dev/null 2>&1 || { echo "adapter-contract: no backend setup for $name in $0" >&2; exit 2; }
write_config() {
  { printf 'adapters:\n  default: %s\nbase: main\nnotify:\n  desktop: false\n' "$name"
    [ "$1" = 1 ] && printf 'ready:\n  needs: [priority]\n  priority_order: [P0, P1, P2, P3]\n'
    "config_$name" "$1"
  } > "$FLOW_HOME/config.yaml"
}
"setup_$name"; write_config 0

echo "contract: $name"
echo " the folder"
prefix="$(head -n 1 "$A/prefix" 2>/dev/null)"
check "the prefix file holds one non-empty line" '[ -n "$prefix" ] && [ "$(wc -l < "$A/prefix" | tr -d " ")" = 1 ]'
for op in list list-ready read in-scope create close comment link-pr write-state; do
  check "$op.sh is there and executable" '[ -x "$A/$op.sh" ]'
done
for op in sync vocabulary answers; do
  if [ -e "$A/$op.sh" ]; then check "the optional $op.sh is executable" '[ -x "$A/$op.sh" ]'; fi
done
check "slug.sed is there" '[ -f "$A/slug.sed" ]'
check "no other adapter's prefix starts this one or is started by it" '! for f in "$P"/adapters/*/prefix; do
  [ "$f" = "$A/prefix" ] && continue; other="$(head -n 1 "$f")"
  case "$prefix" in "$other"*) echo clash ;; esac; case "$other" in "$prefix"*) echo clash ;; esac
done | grep -q clash'

echo " usage"
for op in read create close comment link-pr write-state; do
  check "$op with no arguments exits 2" '[ "$(code_of "$A/$op.sh")" = 2 ]'
done
check "list with an unknown option exits 2" '[ "$(code_of "$A/list.sh" --no-such-option)" = 2 ]'
check "read of an id another adapter owns exits 2" '[ "$(code_of "$A/read.sh" "nobody:1")" = 2 ]'

echo " create and read"
epic="$("$A/create.sh" epic "Contract epic" --body "The epic body.")"
t1="$("$A/create.sh" task "Contract task one" --size S --priority P1 --area Bots --parent "$epic" --body "Body of task one.")"
t2="$("$A/create.sh" task "Contract task two" --size M --blocked-by "$t1" --type Feature)"
bug="$("$A/create.sh" bug "Contract bug")"
check "create prints one id per item, each the prefix starts" 'for i in "$epic" "$t1" "$t2" "$bug"; do case "$i" in "$prefix"?*) ;; *) exit 1 ;; esac; [ "$(printf "%s\n" "$i" | wc -l | tr -d " ")" = 1 ] || exit 1; done'
check "create gives each item its own id" '[ "$(printf "%s\n" "$epic" "$t1" "$t2" "$bug" | sort -u | wc -l | tr -d " ")" = 4 ]'
check "ids hold only the id characters" '! printf "%s\n" "$epic" "$t1" "$t2" "$bug" | grep -q "[^A-Za-z0-9:#/_.-]"'
check "lib/flow.sh routes the id to this adapter" '[ "$(adapter_for "$t1")" = "$name" ]'
check "slug.sed turns the slug of an id back into the id" '[ "$(slug_item "$(item_slug "$t1")")" = "$t1" ]'
check "a read has every field of the contract, each of its type" '[ -z "$("$A/read.sh" "$t1" | shape)" ]'
check "a list has every field of the contract in each item" '[ -z "$("$A/list.sh" | python3 -c "import json,sys; [print(json.dumps(i)) for i in json.load(sys.stdin)]" | while read -r line; do printf "%s" "$line" | shape; done)" ]'
check "read gives back the id" '[ "$(field "$t1" id)" = "$t1" ]'
check "read gives back the title" '[ "$(field "$t1" title)" = "Contract task one" ]'
check "read gives back the body text" 'field "$t1" body | grep -q "Body of task one."'
check "read gives back the kind of a task, an epic and a bug" '[ "$(field "$t1" kind)" = task ] && [ "$(field "$epic" kind)" = epic ] && [ "$(field "$bug" kind)" = bug ]'
check "--type names the tracker type and leaves the kind a task" '[ "$(field "$t2" kind)" = task ]'
check "a new item is open" '[ "$(field "$t1" status)" = open ]'
check "read gives back the size" '[ "$(field "$t1" size)" = S ]'
check "read gives back the priority" '[ "$(field "$t1" priority)" = P1 ]'
check "read gives back the area" '[ "$(field "$t1" area)" = Bots ]'
check "read gives back the parent" '[ "$(field "$t1" parent)" = "$epic" ]'
check "read gives back the blockers" '[ "$(field "$t2" blocked_by)" = "[\"$t1\"]" ]'
check "a blocker is not blocked by the task it blocks" '[ "$(field "$t1" blocked_by)" = "[]" ]'
check "a parent counts its open child" '[ "$(field "$epic" open_children)" = 1 ]'
check "a new item has no step, no gate, no attempts, no touches" '[ -z "$(field "$t1" state.step)" ] && [ "$(field "$t1" state.gate)" = none ] && [ "$(field "$t1" state.attempts)" = 0 ] && [ "$(field "$t1" state.touches)" = "[]" ]'
missing="$("missing_$name")"
check "read of an id that names no item fails with nothing on stdout" '! "$A/read.sh" "$missing" > "$work/out" 2>/dev/null && [ ! -s "$work/out" ]'

echo " list"
check "list names every open item" 'for i in "$epic" "$t1" "$t2" "$bug"; do listed "$i" "$A/list.sh" || exit 1; done'
check "list --kind bug names the bug" 'listed "$bug" "$A/list.sh" --kind bug'
check "list --kind bug leaves the tasks out" '! listed "$t1" "$A/list.sh" --kind bug'
check "list-ready names an unblocked task" 'listed "$t1" "$A/list-ready.sh"'
check "list-ready leaves out a task with an open blocker" '! listed "$t2" "$A/list-ready.sh"'
check "list-ready leaves out an epic with an open child" '! listed "$epic" "$A/list-ready.sh"'

echo " state"
"$A/write-state.sh" "$t1" step=implement profile=task-S worktree=wt-1 attempts=2 "last_event=2026-11-01T10:00:00Z start implement" "touches=src/a/**,docs/*" size=M >/dev/null 2>&1
check "write-state: the step reads back" '[ "$(field "$t1" state.step)" = implement ]'
check "write-state: the profile reads back" '[ "$(field "$t1" state.profile)" = task-S ]'
check "write-state: the worktree reads back" '[ "$(field "$t1" state.worktree)" = wt-1 ]'
check "write-state: attempts read back as a number" '[ "$(field "$t1" state.attempts)" = 2 ]'
check "write-state: the last event reads back whole" '[ "$(field "$t1" state.last_event)" = "2026-11-01T10:00:00Z start implement" ]'
check "write-state: touches read back as a list" '[ "$(field "$t1" state.touches)" = "[\"src/a/**\", \"docs/*\"]" ]'
"$A/write-state.sh" "$t1" "changes=src/a/x.cs" held_by=gh#9 "held_reason=shares src/a/x.cs" >/dev/null 2>&1
check "write-state: changes, held_by and held_reason read back" '[ "$(field "$t1" state.changes)" = "[\"src/a/x.cs\"]" ] && [ "$(field "$t1" state.held_by)" = "gh#9" ] && [ "$(field "$t1" state.held_reason)" = "shares src/a/x.cs" ]'
"$A/write-state.sh" "$t1" changes= held_by= held_reason= >/dev/null 2>&1
check "write-state: empty values clear changes and the hold" '[ "$(field "$t1" state.changes)" = "[]" ] && [ -z "$(field "$t1" state.held_by)" ]'
check "write-state: a new size is the item size too" '[ "$(field "$t1" size)" = M ] && [ "$(field "$t1" state.size)" = M ]'
"$A/write-state.sh" "$t1" base=epic/9 >/dev/null 2>&1
check "WriteStateBase_ReadsBackAsStateBase: the base a claim records is the item's state.base, which every reader of a claim-less step falls back on" '[ "$(field "$t1" state.base)" = epic/9 ]'
"$A/write-state.sh" "$t1" base= >/dev/null 2>&1
check "WriteStateEmptyBase_ClearsIt: an empty base reads back empty, so the readers fall back on the config base" '[ -z "$(field "$t1" state.base)" ]'
"$A/write-state.sh" "$t1" branch=bugfix/proj-7-stuck-ball >/dev/null 2>&1
check "WriteStateBranch_ReadsBackAsStateBranch: the task branch a claim records is the item's state.branch, which a re-claim and the readers take" '[ "$(field "$t1" state.branch)" = bugfix/proj-7-stuck-ball ]'
"$A/write-state.sh" "$t1" branch= >/dev/null 2>&1
check "WriteStateEmptyBranch_ClearsIt: an empty branch reads back empty, so the next claim names the branch from the template" '[ -z "$(field "$t1" state.branch)" ]'
"$A/write-state.sh" "$t1" gate=plan-approval gate_from=implement >/dev/null 2>&1
check "write-state: a gate and its from step read back" '[ "$(field "$t1" state.gate)" = plan-approval ] && [ "$(field "$t1" state.gate_from)" = implement ]'
check "list-ready leaves out an item at a gate" '! listed "$t1" "$A/list-ready.sh"'
"$A/write-state.sh" "$t1" gate=none gate_from= "answered=plan-approval" "asked=Which way?" "answer=the short way" answered_at=2026-11-01T11:00:00Z answer_pending=next >/dev/null 2>&1
check "write-state: gate none clears the gate" '[ "$(field "$t1" state.gate)" = none ]'
check "write-state: the answer keys read back" '[ "$(field "$t1" state.answered)" = plan-approval ] && [ "$(field "$t1" state.asked)" = "Which way?" ] && [ "$(field "$t1" state.answer)" = "the short way" ] && [ "$(field "$t1" state.answered_at)" = 2026-11-01T11:00:00Z ] && [ "$(field "$t1" state.answer_pending)" = next ]'
"$A/write-state.sh" "$t1" answer_pending= >/dev/null 2>&1
check "write-state: an empty answer_pending says no answer waits" '[ -z "$(field "$t1" state.answer_pending)" ]'
check "list-ready names the item again once its gate is cleared" 'listed "$t1" "$A/list-ready.sh"'
"$A/write-state.sh" "$t1" step= worktree= touches= >/dev/null 2>&1
check "write-state: empty values clear the step, the worktree and the touches" '[ -z "$(field "$t1" state.step)" ] && [ -z "$(field "$t1" state.worktree)" ] && [ "$(field "$t1" state.touches)" = "[]" ]'
check "write-state: an unknown key exits 2" '[ "$(code_of "$A/write-state.sh" "$t1" step=review no_such_key=1)" = 2 ]'
check "write-state: a refused write leaves the state as it was" '[ -z "$(field "$t1" state.step)" ]'
check "write-state on an id that names no item fails" '[ "$(code_of "$A/write-state.sh" "$missing" step=implement)" != 0 ]'
"$A/write-state.sh" "$bug" step=done >/dev/null 2>&1
check "list-ready leaves out an item whose steps are done" '! listed "$bug" "$A/list-ready.sh"'
"$A/write-state.sh" "$bug" step= >/dev/null 2>&1

echo " comment, link-pr, close"
"$A/comment.sh" "$t1" --body "contract comment from --body" >/dev/null 2>&1
printf 'contract comment from stdin\n' | "$A/comment.sh" "$t1" >/dev/null 2>&1
check "comment --body lands on the item" '"comments_$name" "$t1" | grep -q "contract comment from --body"'
check "comment from stdin lands on the item" '"comments_$name" "$t1" | grep -q "contract comment from stdin"'
"$A/link-pr.sh" "$t2" https://example.test/pull/7 >/dev/null 2>&1
check "link-pr records the PR in the state" '[ "$(field "$t2" state.pr)" = https://example.test/pull/7 ]'
check "link-pr says the PR in a comment" '"comments_$name" "$t2" | grep -q "https://example.test/pull/7"'
env -u CLAUDECODE CODEX_THREAD_ID=t "$A/link-pr.sh" "$t2" https://example.test/pull/8 >/dev/null 2>&1
check "link-pr records the host that wrote the PR as pr_host" '[ "$(field "$t2" state.pr_host)" = codex ]'
"$A/close.sh" "$t1" --comment "closed by the contract" >/dev/null 2>&1
check "close makes the item closed" '[ "$(field "$t1" status)" = closed ]'
check "close --comment lands on the item" '"comments_$name" "$t1" | grep -q "closed by the contract"'
check "list leaves out a closed item" '! listed "$t1" "$A/list.sh"'
check "list --all names a closed item" 'listed "$t1" "$A/list.sh" --all'
check "a closed blocker frees its task for list-ready" 'listed "$t2" "$A/list-ready.sh"'
check "a parent stops counting a closed child" '[ "$(field "$epic" open_children)" = 0 ]'

echo " readiness: ready.needs and ready.priority_order"
if [ "$ready_lib" = 1 ] || "$A/read.sh" "$t2" | python3 -c 'import json,sys; sys.exit(0 if "needs" in json.load(sys.stdin) else 1)'; then
  write_config 1
  r0="$("$A/create.sh" task "Ready at P0" --priority P0)"
  r2="$("$A/create.sh" task "Ready at P2" --priority P2)"
  rn="$("$A/create.sh" task "No priority yet")"
  check "an unstarted item without a needed field lists it under needs" '[ "$(field "$rn" needs)" = "[\"priority\"]" ]'
  check "an item with every needed field needs nothing" '[ "$(field "$r0" needs)" = "[]" ]'
  check "list-ready leaves out an item that needs a field" '! listed "$rn" "$A/list-ready.sh"'
  check "the priority order ranks P0 before P2" '[ "$(field "$r0" rank)" -lt "$(field "$r2" rank)" ]'
  check "list-ready puts the higher priority first" 'before "$r0" "$r2" "$A/list-ready.sh"'
  ready_at_priority_two_made_later="$("$A/create.sh" task "Ready at P2, made later" --priority P2)"
  check "ReadyItemsOfOnePriority_OldestFirst: of two items of one priority list-ready names the one made first, because a tie must not go to the newest" 'before "$r2" "$ready_at_priority_two_made_later" "$A/list-ready.sh"'
  write_config 0
else
  skip "the items carry no needs and lib/flow.sh has no ready_rules yet"
fi

if [ -x "$A/answers.sh" ]; then
  echo " answers"
  "$P/scripts/gate.sh" raise "$t2" plan-approval "Which way?" plan >/dev/null 2>&1
  "$A/comment.sh" "$t2" --body "/answer the long way" >/dev/null 2>&1
  "$A/answers.sh" > "$work/answers.out" 2>/dev/null
  check "answers prints the id of the item it cleared" 'grep -qx "$t2" "$work/answers.out"'
  check "answers clears the gate with the answer" '[ "$(field "$t2" state.gate)" = none ] && [ "$(field "$t2" state.answer)" = "the long way" ]'
fi
if [ -x "$A/vocabulary.sh" ]; then
  echo " vocabulary"
  check "vocabulary prints types and areas as lists" '"$A/vocabulary.sh" | python3 -c "import json,sys; v=json.load(sys.stdin); sys.exit(0 if isinstance(v[\"types\"], list) and isinstance(v[\"areas\"], list) else 1)"'
fi
if [ -x "$A/sync.sh" ]; then
  echo " sync"
  check "sync of every item exits 0" '[ "$(code_of "$A/sync.sh")" = 0 ]'
fi

echo " routing"
printf '[{"id":"%s","status":"open","state":{"gate":"none"},"blocked_by":["%s"]},{"id":"%s","status":"open","state":{"gate":"none"},"blocked_by":["%s"]}]' \
  "local:task/801" "$t1" "local:task/802" "$t2" | "$P/scripts/filter-ready.sh" > "$work/ready.out" 2>/dev/null
check "filter-ready reads a blocker through this adapter: a closed one frees the item" 'grep -q "local:task/801" "$work/ready.out"'
check "filter-ready reads a blocker through this adapter: an open one holds the item" '! grep -q "local:task/802" "$work/ready.out"'
if type "blip_$name" >/dev/null 2>&1; then
  "blip_$name"
  check "a read survives one 5xx answer from the backend" '[ "$("$A/read.sh" "$t2" 2>"$work/blip.err" | jget id)" = "$t2" ] && grep -q "trying again" "$work/blip.err"'
fi

# Pick filters (adapters/README.md, Pick filters): each field of pick.<name> narrows list and
# list-ready as the adapter maps it. Per backend: set_<name> <id> assignee|label <value> writes the
# store as the tracker would hold an assignment or a label, me_<name> is the login `me` stands for,
# open_status_<name> the status a new item has, query_<name> <label> a search of its own for the
# label (none where the adapter maps no query).
echo " pick filters"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.email GIT_CONFIG_VALUE_0=me@contract.test
set_local() {
  python3 -c 'import sys
p, key, value = sys.argv[1:]
text = open(p).read(); end = text.find("\n---\n", 4)
line = "labels: [%s]" % value if key == "label" else "assignee: %s" % value
open(p, "w").write(text[:end] + "\n" + line + text[end:])' "$FLOW_HOME/items/${1#local:}.md" "$2" "$3"
}
set_github() {
  python3 -c 'import json, sys
p, number, key, value = sys.argv[1:]; data = json.load(open(p))
issue = [i for i in data["issues"] if i["number"] == int(number)][0]
issue["assignees" if key == "assignee" else "labels"] = [value]
json.dump(data, open(p, "w"))' "$FAKE_GH_DIR/issues.json" "${1#gh#}" "$2" "$3"
}
set_jira() {
  python3 -c 'import json, sys
p, key, field, value = sys.argv[1:]; data = json.load(open(p)); fields = data["issues"][key]["fields"]
if field == "label": fields["labels"] = [value]
else: fields["assignee"] = {"accountId": "id-" + value, "emailAddress": value, "displayName": value}
json.dump(data, open(p, "w"))' "$FAKE_JIRA_DIR/jira.json" "${1#jira:}" "$2" "$3"
}
me_local() { echo me@contract.test; }
me_github() { echo owner; }
me_jira() { echo flow@acme.test; }
open_status_local() { echo open; }
open_status_github() { echo open; }
open_status_jira() { echo "To Do"; }
query_github() { echo "label:$1"; }
query_jira() { echo "labels = \"$1\""; }
other_tracker() { if [ "$name" = local ]; then echo github; else echo local; fi; }
pick_config() { write_config 0; printf 'pick:\n%s\n' "$1" >> "$FLOW_HOME/config.yaml"; }
if type "set_$name" >/dev/null 2>&1; then
  pa="$("$A/create.sh" task "Pick: mine, labelled")"
  pb="$("$A/create.sh" bug "Pick: theirs")"
  pc="$("$A/create.sh" task "Pick: nobody's")"
  "$A/create.sh" task "Pick: the epic's child, unlabelled" --parent "$epic" >/dev/null
  "set_$name" "$pa" assignee "$("me_$name")"; "set_$name" "$pa" label picked
  "set_$name" "$pb" assignee someone@contract.test
  "set_$name" "$epic" label picked
  check "pick-fields names only the fields a filter has" '[ -s "$A/pick-fields" ] && for f in $(cat "$A/pick-fields"); do case " assignee status labels kinds query " in *" $f "*) ;; *) exit 1 ;; esac; done'
  pick_config '  mine:
    assignee: me
  theirs:
    assignee: someone@contract.test
  labelled:
    labels: [picked]
  bugs:
    kinds: [bug]
  open:
    status: ['"$("open_status_$name")"']
  shut:
    status: [Nonesuch]
  elsewhere:
    trackers: ['"$(other_tracker)"']
  odd:
    sprint: 12
  loose:
    query: anything
  mixed:
    query: anything
    trackers: ['"$name"']
    labels: [picked]'
  check "list without --pick still lists every open item" 'listed "$pa" "$A/list.sh" && listed "$pb" "$A/list.sh" && listed "$pc" "$A/list.sh"'
  check "assignee: me keeps the items assigned to the user the adapter acts as" 'listed "$pa" "$A/list-ready.sh" --pick mine && ! listed "$pb" "$A/list-ready.sh" --pick mine && ! listed "$pc" "$A/list-ready.sh" --pick mine'
  check "assignee: a login keeps the items assigned to it" 'listed "$pb" "$A/list-ready.sh" --pick theirs && ! listed "$pa" "$A/list-ready.sh" --pick theirs'
  check "labels keeps the items with one of them" 'listed "$pa" "$A/list-ready.sh" --pick labelled && ! listed "$pb" "$A/list-ready.sh" --pick labelled'
  check "a filter that leaves a parent's children out still counts them open" '"$A/list.sh" --pick labelled | python3 -c "import json,sys; sys.exit(0 if [i[\"open_children\"] for i in json.load(sys.stdin) if i[\"id\"] == sys.argv[1]] == [1] else 1)" "$epic"'
  check "kinds keeps the items of one of them" 'listed "$pb" "$A/list-ready.sh" --pick bugs && ! listed "$pa" "$A/list-ready.sh" --pick bugs'
  check "status keeps the items in one of them" 'listed "$pa" "$A/list-ready.sh" --pick open && ! listed "$pa" "$A/list-ready.sh" --pick shut'
  check "a filter whose trackers leave the adapter out lists nothing" '[ "$("$A/list.sh" --pick elsewhere)" = "[]" ]'
  check "an unknown filter exits 2 naming the filters there are" '[ "$(code_of "$A/list.sh" --pick nonesuch)" = 2 ] && "$A/list.sh" --pick nonesuch 2>&1 | grep -q "the filters are mine theirs"'
  check "a field the adapter does not map exits 2 naming the ones it maps" '[ "$(code_of "$A/list.sh" --pick odd)" = 2 ] && "$A/list.sh" --pick odd 2>&1 | grep -q "pick.odd.sprint: the $name adapter maps .*assignee.*, not sprint"'
  check "a query without exactly one tracker exits 2" '[ "$(code_of "$A/list.sh" --pick loose)" = 2 ]'
  check "a query beside a neutral field exits 2" '[ "$(code_of "$A/list.sh" --pick mixed)" = 2 ]'
  pick_config '  own:
    query: '"'$(type "query_$name" >/dev/null 2>&1 && "query_$name" picked || printf %s "label = picked")'"'
    trackers: ['"$name"']'
  if grep -qw query "$A/pick-fields"; then
    check "query goes to the tracker as written and keeps what its search keeps" 'listed "$pa" "$A/list-ready.sh" --pick own && ! listed "$pb" "$A/list-ready.sh" --pick own'
  else
    check "query exits 2 where the adapter has no search of its own" '[ "$(code_of "$A/list.sh" --pick own)" = 2 ]'
  fi
  write_config 0
else
  skip "no set_$name in this suite to assign or label an item"
fi

# Tracker scope (adapters/README.md, Tracker scope): <name>.scope bounds every list and list-ready,
# beside a pick, and in-scope.sh says whether one item is inside it. Per backend:
# scope_config_<name> <lines> prints the scope block for the end of the adapter's own config
# section, which config_<name> writes last.
scope_config_local() { printf 'local:\n  scope:\n%s\n' "$1"; }
scope_config_github() { printf '  scope:\n%s\n' "$1"; }
scope_config() { # scope_config <scope lines> [<pick lines>]
  write_config 0; "scope_config_$name" "$1" >> "$FLOW_HOME/config.yaml"
  [ -z "${2:-}" ] || printf 'pick:\n%s\n' "$2" >> "$FLOW_HOME/config.yaml"
}
if type "set_$name" >/dev/null 2>&1 && type "scope_config_$name" >/dev/null 2>&1; then
  echo " tracker scope"
  ps="$("$A/create.sh" task "Scope: mine, unlabelled")"
  "set_$name" "$ps" assignee "$("me_$name")"
  write_config 0
  check "InScope_NoScopeSet_ExitsZero: in-scope exits 0 for any item when the tracker has no scope, because unset reads as today" '[ "$(code_of "$A/in-scope.sh" "$pb")" = 0 ]'
  scope_config '    assignee: me'
  check "ScopedListAssigneeMe_KeepsItemAssigned: a scope assignee of me keeps an item assigned to the user the adapter acts as, because me stands for that user" 'listed "$pa" "$A/list.sh"'
  check "ScopedListAssigneeMe_DropsItemOfOthers: a scope assignee of me leaves out an item assigned to someone else, because the scope narrows every list to its assignee" '! listed "$pb" "$A/list.sh"'
  scope_config '    kinds: [bug]'
  check "ScopedListKinds_KeepsItemOfKind: a scope of kinds keeps an item of one of them, because a scope only narrows" 'listed "$pb" "$A/list.sh"'
  check "ScopedListKinds_DropsItemOfOtherKind: a scope of kinds leaves out an item of another kind, because every list is bounded by the scope" '! listed "$pa" "$A/list.sh"'
  check "InScopeKinds_ItemOfOtherKind_ExitsOne: in-scope exits 1 for an item whose kind the scope leaves out, because in-scope reads the scope as list does" '[ "$(code_of "$A/in-scope.sh" "$pa")" = 1 ]'
  if grep -qw query "$A/pick-fields"; then
    scope_config "    query: '$("query_$name" picked)'"
    check "ScopedListQuery_KeepsItemTheSearchMatches: a scope query goes to the tracker's search and keeps what it matches, because a query goes to the tracker as written" 'listed "$pa" "$A/list.sh"'
    check "ScopedListQuery_DropsItemTheSearchMisses: a scope query leaves out an item the tracker's search does not match, because every list is bounded by the scope" '! listed "$pb" "$A/list.sh"'
    check "InScopeQuery_ItemTheSearchMisses_ExitsOne: in-scope exits 1 for an item the scope query does not match, because in-scope reads the scope as list does" '[ "$(code_of "$A/in-scope.sh" "$pb")" = 1 ]'
  fi
  scope_config '    labels: [picked]'
  check "ScopedList_KeepsItemInside: list names an item the scope matches, because the scope only narrows" 'listed "$pa" "$A/list.sh"'
  check "ScopedList_DropsItemOutside: list leaves out an item the scope does not match, because every read is bounded by it" '! listed "$pb" "$A/list.sh"'
  check "ScopedListReady_KeepsItemInside: list-ready names a ready item the scope matches, because the scope only narrows" 'listed "$pa" "$A/list-ready.sh"'
  check "ScopedListReady_DropsItemOutside: list-ready leaves out a ready item the scope does not match, because it reads the scoped list" '! listed "$pb" "$A/list-ready.sh"'
  check "InScope_ItemInside_ExitsZero: in-scope exits 0 for an item the scope matches, because the flow runs an item inside its scope" '[ "$(code_of "$A/in-scope.sh" "$pa")" = 0 ]'
  check "InScope_ItemOutside_ExitsOne: in-scope exits 1 for an item the scope does not match, because the flow runs no item outside its scope" '[ "$(code_of "$A/in-scope.sh" "$pb")" = 1 ]'
  check "InScope_NoArguments_ExitsTwo: in-scope with no id is a usage error, because there is no item to say anything of" '[ "$(code_of "$A/in-scope.sh")" = 2 ]'
  write_config 0; "scope_config_$name" '    labels: [picked]' | sed 's/^  scope:$/  "scope":/' >> "$FLOW_HOME/config.yaml"
  check "InScopeQuotedScopeKey_ItemOutside_ExitsOne: in-scope exits 1 for an item outside a scope under a quoted key, because a quoted key is the same scope every list applies" '[ "$(code_of "$A/in-scope.sh" "$pb")" = 1 ]'
  check "InScopeQuotedScopeKey_ItemInside_ExitsZero: in-scope exits 0 for an item inside a scope under a quoted key, because the quoted scope only narrows" '[ "$(code_of "$A/in-scope.sh" "$pa")" = 0 ]'
  write_config 0; "scope_config_$name" '    labels: [picked]' | sed -e 's/^  scope:/  # scope:/' -e 's/^    labels:/    # labels:/' >> "$FLOW_HOME/config.yaml"
  check "CommentedOutScope_ListKeepsItemOutsideIt: a scope only in comments lists an item it would leave out, because a commented scope is unset" 'listed "$pb" "$A/list.sh"'
  check "InScopeCommentedOutScope_ItemOutsideIt_ExitsZero: in-scope exits 0 for an item a commented scope would leave out, because a commented scope is unset" '[ "$(code_of "$A/in-scope.sh" "$pb")" = 0 ]'
  scope_config '    labels: [picked]' '  mine:
    assignee: me'
  check "ScopeAndPick_ItemBothMatch_IsListed: a pick inside a scope keeps the item both match, because the scope and the pick compose" 'listed "$pa" "$A/list.sh" --pick mine'
  check "ScopeAndPick_ItemOnlyPickMatches_IsLeftOut: a pick inside a scope leaves out an item outside the scope, because both apply" '! listed "$ps" "$A/list.sh" --pick mine'
  check "ScopeAndPick_ItemOnlyScopeMatches_IsLeftOut: a pick inside a scope leaves out an item the pick does not match, because both apply" '! listed "$epic" "$A/list.sh" --pick mine'
  scope_config '    sprint: 12'
  check "ScopeUnmappedField_ExitsTwo: a scope field the adapter does not map stops the list, because an unmapped field would narrow nothing" '[ "$(code_of "$A/list.sh")" = 2 ]'
  check "ScopeUnmappedField_NamesScopeKey: the refusal names <tracker>.scope.<field> and the fields the adapter maps, because that is the key to change" '"$A/list.sh" 2>&1 | grep -q "$name.scope.sprint: the $name adapter maps .*assignee.*, not sprint"'
  scope_config '    sprint: 12'
  check "InScope_RefusedScope_ExitsTwo: in-scope exits 2 for a scope the checks refuse, because no item is inside a broken scope" '[ "$(code_of "$A/in-scope.sh" "$pa")" = 2 ]'
  write_config 0; "scope_config_$name" '' | sed 's/^  scope:$/  scope: "labels = picked"/' >> "$FLOW_HOME/config.yaml"
  check "ScopeWrittenAsValue_ListExitsTwo: a scope written as a value stops the list, because a scope it cannot read would list every item" '[ "$(code_of "$A/list.sh")" = 2 ]'
  check "InScope_ScopeWrittenAsValue_ExitsTwo: in-scope exits 2 under a scope written as a value, because an unread scope is no missing scope" '[ "$(code_of "$A/in-scope.sh" "$pb")" = 2 ]'
  scope_config '    labels:
    - picked'
  check "ScopeFieldListAtItsIndent_ListExitsTwo: a scope field whose list sits at the field's own indent stops the list, because a field no value of which reads would list every item" '[ "$(code_of "$A/list.sh")" = 2 ]'
  check "InScope_ScopeFieldListAtItsIndent_ExitsTwo: in-scope exits 2 under a scope field whose list sits at its own indent, because an unread field is no unset field" '[ "$(code_of "$A/in-scope.sh" "$pb")" = 2 ]'
  scope_config '    labels:
      team: picked'
  check "ScopeFieldNestedMap_ListExitsTwo: a scope field written as a map stops the list, because a field no value of which reads would list every item" '[ "$(code_of "$A/list.sh")" = 2 ]'
  scope_config '    labels:
    kinds: [bug]'
  check "ScopeFieldWithNothingUnder_KeepsItemOtherFieldsMatch: a scope field with nothing under it is unset and the list runs, because an empty field narrows nothing" 'listed "$pb" "$A/list.sh"'
  check "ScopeFieldWithNothingUnder_DropsItemOtherFieldsMiss: the scope's other fields still apply beside a field with nothing under it, because only that field is unset" '! listed "$pa" "$A/list.sh"'
  scope_config '    trackers: [other]'
  check "ScopeTrackers_ExitsTwo: a scope that names trackers stops the list, because a scope belongs to its tracker" '[ "$(code_of "$A/list.sh")" = 2 ]'
  scope_config '    query: anything
    labels: [picked]'
  check "ScopeQueryBesideNeutralField_ExitsTwo: a scope query beside a neutral field stops the list, because a query goes to the tracker as written and takes no other field" '[ "$(code_of "$A/list.sh")" = 2 ]'
  if ! grep -qw query "$A/pick-fields"; then
    scope_config '    query: anything'
    check "ScopeQuery_NoSearchOfItsOwn_ExitsTwo: a scope query stops the list where the adapter has no search of its own, because nothing could run the query" '[ "$(code_of "$A/list.sh")" = 2 ]'
  fi
  write_config 0
else
  skip "no set_$name or scope_config_$name in this suite to scope a list"
fi

echo "contract $name: $checks checks, $fails failed"
[ "$fails" -eq 0 ]
