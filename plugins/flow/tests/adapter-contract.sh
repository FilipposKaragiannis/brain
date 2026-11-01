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
trap 'rm -rf "$work"' EXIT
unset FLOW_SLACK_WEBHOOK
export FLOW_HOME="$work/home"; mkdir -p "$FLOW_HOME" "$work/bin"
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
for op in list list-ready read create close comment link-pr write-state; do
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
check "write-state: a new size is the item size too" '[ "$(field "$t1" size)" = M ] && [ "$(field "$t1" state.size)" = M ]'
"$A/write-state.sh" "$t1" gate=plan-approval gate_from=implement >/dev/null 2>&1
check "write-state: a gate and its from step read back" '[ "$(field "$t1" state.gate)" = plan-approval ] && [ "$(field "$t1" state.gate_from)" = implement ]'
check "list-ready leaves out an item at a gate" '! listed "$t1" "$A/list-ready.sh"'
"$A/write-state.sh" "$t1" gate=none gate_from= "answered=plan-approval" "asked=Which way?" "answer=the short way" answered_at=2026-11-01T11:00:00Z >/dev/null 2>&1
check "write-state: gate none clears the gate" '[ "$(field "$t1" state.gate)" = none ]'
check "write-state: the answer keys read back" '[ "$(field "$t1" state.answered)" = plan-approval ] && [ "$(field "$t1" state.asked)" = "Which way?" ] && [ "$(field "$t1" state.answer)" = "the short way" ] && [ "$(field "$t1" state.answered_at)" = 2026-11-01T11:00:00Z ]'
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

echo "contract $name: $checks checks, $fails failed"
[ "$fails" -eq 0 ]
