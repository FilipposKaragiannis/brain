#!/bin/sh
# Tests for the flow plugin: config parsing, both adapters (GitHub through a fake gh), the
# steward, next/advance, gates, re-sizing, overlap, the board and the worktree hooks. Builds a
# throwaway repo with a two-worktree pool. Run from anywhere. Exit 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$P"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { # check <name> <condition command...>
  name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}
jget() { python3 -c 'import json,sys; v=json.load(sys.stdin)
for k in sys.argv[1].split("."): v = v[int(k)] if k.isdigit() else v[k]
print(v if isinstance(v,str) else json.dumps(v))' "$1"; }

cd "$work"
git init -q -b main repo && cd repo
git config user.email t@t && git config user.name t
printf 'hi\n' > README.md && git add -A && git commit -qm init
git worktree add -q --detach ../wt-1 && git worktree add -q --detach ../wt-2
mkdir -p .flow
cat > .flow/config.yaml <<'YAML'
adapters:
  default: local
base: main
pool:
  - ../wt-1
  - ../wt-2
notify:
  desktop: false
YAML
repo="$PWD"

echo "config"
. "$P/lib/flow.sh"
check "yaml scalar"       [ "$(yaml_get .flow/config.yaml base)" = "main" ]
check "yaml nested"       [ "$(yaml_get .flow/config.yaml adapters.default)" = "local" ]
check "yaml list"         [ "$(yaml_get .flow/config.yaml pool | wc -l | tr -d ' ')" = "2" ]
check "yaml missing"      [ -z "$(yaml_get .flow/config.yaml nothing.here)" ]
check "slug"              [ "$(item_slug 'gh#12')" = "gh-12" ] && [ "$(item_slug local:bug/3)" = "local-bug-3" ]
check "profile select"    [ "$(profile_select task S)" = "task-S" ] && [ "$(profile_select bug M)" = "bugfix" ] && [ "$(profile_select task XL)" = "task-L" ]

echo "local adapter"
t1="$("$P/adapters/local/create.sh" task "First task" --size S --body "Do it.")"
b1="$("$P/adapters/local/create.sh" bug "A bug" --blocked-by "$t1")"
t2="$("$P/adapters/local/create.sh" task "Medium task")"
check "create ids"        [ "$t1" = "local:task/1" ] && [ "$b1" = "local:bug/1" ] && [ "$t2" = "local:task/2" ]
check "read title"        [ "$("$P/adapters/local/read.sh" "$t1" | jget title)" = "First task" ]
check "read default size" [ "$("$P/adapters/local/read.sh" "$t2" | jget size)" = "" ]
"$P/adapters/local/write-state.sh" "$t1" step=implement attempts=2 touches=src/a/**,docs/*
check "write-state"       [ "$("$P/adapters/local/read.sh" "$t1" | jget state.step)" = "implement" ] && [ "$("$P/adapters/local/read.sh" "$t1" | jget state.touches)" = '["src/a/**", "docs/*"]' ]
"$P/adapters/local/write-state.sh" "$t1" step= attempts=0 touches=
printf 'hello: world\n' | "$P/adapters/local/comment.sh" "$t1"
check "comment appended"  grep -q 'hello: world' .flow/items/task/1.md
check "list open"         [ "$("$P/adapters/local/list.sh" | jget 2.id)" = "local:task/2" ]
check "ready excludes blocked" [ "$("$P/adapters/local/list-ready.sh" | python3 -c 'import json,sys; print(",".join(i["id"] for i in json.load(sys.stdin)))')" = "local:task/1,local:task/2" ]
"$P/adapters/local/link-pr.sh" "$t2" https://example/pr/1
check "link-pr"           [ "$("$P/adapters/local/read.sh" "$t2" | jget state.pr)" = "https://example/pr/1" ]
"$P/adapters/local/write-state.sh" "$t2" pr=

echo "steward"
w1="$("$P/scripts/steward.sh" claim "$t1")"
check "claim path"        [ "$w1" = "$(cd ../wt-1 && pwd -P)" ]
check "claim branch"      [ "$(git -C "$w1" symbolic-ref --short HEAD)" = "flow/local-task-1" ]
check "claim file"        [ "$(jget item < "$w1/.flow/claim.json")" = "$t1" ]
check "claim in tracker"  [ "$("$P/adapters/local/read.sh" "$t1" | jget state.worktree)" = "wt-1" ]
check "claim again same"  [ "$("$P/scripts/steward.sh" claim "$t1")" = "$w1" ]
check "find"              [ "$("$P/scripts/steward.sh" find "$t1")" = "$w1" ]
printf 'x\n' > "$w1/dirty.txt"
"$P/scripts/steward.sh" release "$t1" >/dev/null 2>&1; code=$?
check "release refuses dirty (exit 3)" [ "$code" -eq 3 ] && [ -f "$w1/.flow/claim.json" ]
rm "$w1/dirty.txt"
check "release clean"     "$P/scripts/steward.sh" release "$t1"
check "released: detached, no claim, tracker cleared" [ ! -f "$w1/.flow/claim.json" ] && ! git -C "$w1" symbolic-ref -q HEAD && [ -z "$("$P/adapters/local/read.sh" "$t1" | jget state.worktree)" ]
check "pool table"        sh -c "'$P/scripts/steward.sh' pool | grep -q 'wt-2.*free'"

echo "next and advance"
out="$("$P/scripts/next.sh" --json)"; code=$?
check "next picks first ready" [ "$code" -eq 0 ] && [ "$(printf '%s' "$out" | jget item)" = "$t1" ] && [ "$(printf '%s' "$out" | jget step)" = "implement" ]
brief="$(printf '%s' "$out" | jget brief)"; reports="$(printf '%s' "$out" | jget reports)"
check "brief written in the worktree" [ -f "$brief" ] && grep -q 'cd "' "$brief" && grep -q 'implement.json' "$brief"
check "run recorded"      [ -f .flow/runs/local-task-1.json ]
check "state step"        [ "$("$P/adapters/local/read.sh" "$t1" | jget state.step)" = "implement" ] && [ "$("$P/adapters/local/read.sh" "$t1" | jget state.profile)" = "task-S" ]
"$P/scripts/next.sh" "$t1" >/dev/null 2>&1; code=$?
check "second next on a running item: exit 7" [ "$code" -eq 7 ]
out2="$("$P/scripts/next.sh" --json)"
check "next picks the other item in wt-2" [ "$(printf '%s' "$out2" | jget item)" = "$t2" ] && [ "$(printf '%s' "$out2" | jget step)" = "design" ] && [ "$(basename "$(printf '%s' "$out2" | jget worktree)")" = "wt-2" ]
"$P/scripts/next.sh" >/dev/null 2>&1; code=$?
check "nothing ready: exit 5" [ "$code" -eq 5 ]
"$P/scripts/advance.sh" "$t1" >/dev/null 2>&1; code=$?
check "advance without a result: exit 2" [ "$code" -eq 2 ]
printf '{"status":"done","summary":"built","touches":["src/a/**"]}\n' > "$reports/implement.json"
check "advance done -> test" sh -c "'$P/scripts/advance.sh' '$t1' --json | grep -q '\"next_step\":\"test\"'"
check "touches stored"    [ "$("$P/adapters/local/read.sh" "$t1" | jget state.touches)" = '["src/a/**"]' ]
check "run cleared"       [ ! -f .flow/runs/local-task-1.json ]
"$P/scripts/next.sh" "$t1" >/dev/null
"$P/scripts/advance.sh" "$t1" --status fail --summary "red" >/dev/null; "$P/scripts/next.sh" "$t1" >/dev/null
check "fail: attempt 1, step test stays" [ "$("$P/adapters/local/read.sh" "$t1" | jget state.attempts)" = "1" ] && [ "$("$P/adapters/local/read.sh" "$t1" | jget state.step)" = "test" ]
"$P/scripts/advance.sh" "$t1" --status fail --summary "red again" >/dev/null; "$P/scripts/next.sh" "$t1" >/dev/null
"$P/scripts/advance.sh" "$t1" --status fail --summary "still red" >/dev/null 2>&1; code=$?
check "third fail: escalation gate (exit 4)" [ "$code" -eq 4 ] && [ "$("$P/adapters/local/read.sh" "$t1" | jget state.gate)" = "escalation" ] && [ -f .flow/gates/local-task-1.json ]
"$P/scripts/next.sh" "$t1" >/dev/null 2>&1; code=$?
check "next at a gate: exit 4" [ "$code" -eq 4 ]
check "gate list"         sh -c "'$P/scripts/gate.sh' list | grep -q escalation"
"$P/scripts/gate.sh" clear "$t1" "fixed" >/dev/null
check "gate cleared"      [ "$("$P/adapters/local/read.sh" "$t1" | jget state.gate)" = "none" ] && [ ! -f .flow/gates/local-task-1.json ] && [ "$("$P/adapters/local/read.sh" "$t1" | jget state.attempts)" = "0" ]
for s in test review; do "$P/scripts/next.sh" "$t1" >/dev/null; printf '{"status":"done"}\n' > "$reports/$s.json"; "$P/scripts/advance.sh" "$t1" >/dev/null; done
"$P/scripts/next.sh" "$t1" >/dev/null
printf '{"status":"fail","attempts":1,"checks":[{"name":"tests","status":"fail","summary":"1 failed"}]}\n' > "$reports/verify.json"
check "verify fail -> back to implement" sh -c "'$P/scripts/advance.sh' '$t1' --json | grep -q '\"next_step\":\"implement\"'"
"$P/scripts/next.sh" "$t1" >/dev/null; printf '{"status":"done"}\n' > "$reports/implement.json"; "$P/scripts/advance.sh" "$t1" >/dev/null
for s in test review; do "$P/scripts/next.sh" "$t1" >/dev/null; "$P/scripts/advance.sh" "$t1" >/dev/null; done
"$P/scripts/next.sh" "$t1" >/dev/null
printf '{"status":"pass","attempts":2,"checks":[{"name":"tests","status":"pass","summary":"ok"}]}\n' > "$reports/verify.json"
check "verify pass -> pr" sh -c "'$P/scripts/advance.sh' '$t1' --json | grep -q '\"next_step\":\"pr\"'"
"$P/scripts/next.sh" "$t1" >/dev/null; printf '{"status":"done","summary":"PR open"}\n' > "$reports/pr.json"
"$P/scripts/advance.sh" "$t1" >/dev/null 2>&1; code=$?
check "pr done -> merge gate (exit 4), step done" [ "$code" -eq 4 ] && [ "$("$P/adapters/local/read.sh" "$t1" | jget state.gate)" = "merge" ] && [ "$("$P/adapters/local/read.sh" "$t1" | jget state.step)" = "done" ]
"$P/scripts/gate.sh" clear "$t1" merged >/dev/null
"$P/scripts/next.sh" "$t1" >/dev/null 2>&1; code=$?
check "next on a done item: exit 6" [ "$code" -eq 6 ]

echo "re-size and gates"
r2="$(printf '%s' "$out2" | jget reports)"
printf '{"status":"done","size":"L","summary":"bigger"}\n' > "$r2/design.json"
"$P/scripts/advance.sh" "$t2" >/dev/null 2>&1; code=$?
check "M -> L stops at plan-approval" [ "$code" -eq 4 ] && [ "$("$P/adapters/local/read.sh" "$t2" | jget state.gate)" = "plan-approval" ] && [ "$("$P/adapters/local/read.sh" "$t2" | jget state.size)" = "L" ]
"$P/scripts/gate.sh" clear "$t2" "replanned" >/dev/null
"$P/scripts/next.sh" "$t2" >/dev/null; printf '{"status":"done"}\n' > "$r2/design.json"
"$P/scripts/advance.sh" "$t2" >/dev/null 2>&1
check "L profile after re-size" [ "$("$P/adapters/local/read.sh" "$t2" | jget state.profile)" = "task-L" ] && [ "$("$P/adapters/local/read.sh" "$t2" | jget state.step)" = "plan" ]
"$P/scripts/next.sh" "$t2" >/dev/null; printf '{"status":"done","summary":"planned"}\n' > "$r2/plan.json"
"$P/scripts/advance.sh" "$t2" >/dev/null 2>&1; code=$?
check "plan -> plan-approval gate, step implement" [ "$code" -eq 4 ] && [ "$("$P/adapters/local/read.sh" "$t2" | jget state.step)" = "implement" ]
"$P/scripts/gate.sh" clear "$t2" approved >/dev/null
"$P/scripts/next.sh" "$t2" >/dev/null
printf '{"status":"gate","gate":"ambiguity","message":"A or B?"}\n' > "$r2/implement.json"
"$P/scripts/advance.sh" "$t2" >/dev/null 2>&1; code=$?
check "agent raises ambiguity" [ "$code" -eq 4 ] && [ "$("$P/adapters/local/read.sh" "$t2" | jget state.gate)" = "ambiguity" ] && grep -q 'A or B' .flow/gates/local-task-2.json
"$P/scripts/gate.sh" clear "$t2" "A" >/dev/null
b2="$("$P/adapters/local/create.sh" bug "Small bug" --size S)"
"$P/scripts/steward.sh" release "$t1" >/dev/null
"$P/scripts/next.sh" "$b2" >/dev/null
rb="$(cat .flow/runs/local-bug-2.json | jget reports)"
printf '{"status":"done","size":"M"}\n' > "$rb/reproduce.json"
check "S -> M continues" sh -c "'$P/scripts/advance.sh' '$b2' --json | grep -q '\"next_step\":\"implement\"'"
check "bugfix profile kept for a bug" [ "$("$P/adapters/local/read.sh" "$b2" | jget state.profile)" = "bugfix" ]

echo "overlap"
"$P/adapters/local/write-state.sh" "$t2" touches=src/a/**
t3="$("$P/adapters/local/create.sh" task "Overlapping" --size S)"
"$P/adapters/local/write-state.sh" "$t3" touches=src/a/sub/**
"$P/scripts/next.sh" "$t2" >/dev/null
"$P/scripts/next.sh" "$t3" >/dev/null 2>&1; code=$?
check "overlapping claim refused? (explicit item runs; pool full)" [ "$code" -ne 0 ]
"$P/adapters/local/close.sh" "$b2" --comment done
"$P/scripts/steward.sh" release "$b2" --force >/dev/null 2>&1
"$P/scripts/next.sh" >/dev/null 2>&1; code=$?
check "queue skips the overlapping item (exit 5)" [ "$code" -eq 5 ]

echo "verify runner"
mkdir -p .standards
cat > .standards/config.json <<'JSON'
{ "version": "0.1.0", "build": "true", "test": "sh -c 'exit 0'", "mutation": "sh -c 'exit 1'",
  "languages": [ { "name": "sh", "extensions": [".sh"], "format": [ { "prefix": "", "command": "sh -c 'for f in {files}; do grep -q TAB \"$f\" && exit 1; done; exit 0'" } ] } ] }
JSON
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\ngates:\n  determinism: '"'"'sh -c "exit 0"'"'"'\n  harness: '"'"'sh -c "echo harness broke; exit 1"'"'"'\nfeel_test_paths:\n  - ui/**\nnotify:\n  desktop: false\n' > .flow/config.yaml
git add -A >/dev/null 2>&1; git commit -qm "config" >/dev/null 2>&1
v1="$("$P/adapters/local/create.sh" task "Verify me" --size S)"
"$P/scripts/next.sh" "$v1" >/dev/null; wv="$("$P/scripts/steward.sh" find "$v1")"
printf 'echo ok\n' > "$wv/tool.sh"; mkdir -p "$wv/ui"; printf 'x\n' > "$wv/ui/panel.txt"; git -C "$wv" add -A >/dev/null; git -C "$wv" commit -qm "feat: tool" >/dev/null
(cd "$wv" && "$P/scripts/verify.sh" "$v1" >/dev/null 2>&1); code=$?
rv="$wv/.flow/reports/local-task-$(printf '%s' "$v1" | sed 's|.*/||')"
check "verify fails on the broken gate (exit 1)" [ "$code" -eq 1 ] && [ "$(jget status < "$rv/verify.json")" = "fail" ]
check "verify checks: build, format, tests, mutation signal, two gates" [ "$(python3 -c 'import json; cs=json.load(open("'"$rv"'/verify.json"))["checks"]; print(",".join(c["name"]+":"+c["status"] for c in cs))')" = "build:pass,format:pass,tests:pass,mutation:signal,gate determinism:pass,gate harness:fail" ]
check "verify summary carries the error text" sh -c "grep -q 'harness broke' '$rv/verify.json'"
check "verify feel_test from changed ui file" [ "$(jget feel_test < "$rv/verify.json")" = "true" ]
check "verify.md twin" sh -c "grep -q 'Feel-test needed' '$rv/verify.md' && grep -q '| build | pass' '$rv/verify.md'"
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\ngates:\n  determinism: '"'"'sh -c "exit 0"'"'"'\nfeel_test_paths:\n  - ui/**\nnotify:\n  desktop: false\n' > .flow/config.yaml
for s in implement test review; do printf '{"status":"done"}\n' > "$rv/$s.json"; "$P/scripts/advance.sh" "$v1" >/dev/null 2>&1; "$P/scripts/next.sh" "$v1" >/dev/null 2>&1; done
(cd "$wv" && "$P/scripts/verify.sh" "$v1" >/dev/null 2>&1); code=$?
check "verify passes without the broken gate" [ "$code" -eq 0 ] && [ "$(jget status < "$rv/verify.json")" = "pass" ]
"$P/scripts/advance.sh" "$v1" >/dev/null 2>&1; code=$?
check "passing verify with feel_test raises the feel-test gate, step pr" [ "$code" -eq 4 ] && [ "$("$P/adapters/local/read.sh" "$v1" | jget state.gate)" = "feel-test" ] && [ "$("$P/adapters/local/read.sh" "$v1" | jget state.step)" = "pr" ]
"$P/scripts/gate.sh" clear "$v1" "looks right" >/dev/null
"$P/scripts/steward.sh" release "$v1" --force >/dev/null 2>&1

echo "parent and create"
c1="$("$P/adapters/local/create.sh" task "Child" --size S --parent "$v1")"
check "local parent"      [ "$("$P/adapters/local/read.sh" "$c1" | jget parent)" = "$v1" ]

echo "board"
board="$("$P/scripts/board.sh")"
check "board pool and items" sh -c "printf '%s' \"$board\" | grep -q '## Pool' && printf '%s' \"$board\" | grep -q 'local:task/2'"
check "board json"        sh -c "'$P/scripts/board.sh' --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d[\"pool\"])==2 and d[\"items\"]'"

echo "worktree hooks"
rm -f .flow/runs/*.json
"$P/scripts/steward.sh" release "$t2" --force >/dev/null 2>&1
path="$(printf '{"name":"local-task-2","cwd":"%s"}' "$PWD" | "$P/hooks/worktree-create.sh" 2>/dev/null | tail -1)"
check "WorktreeCreate claims a pool path" [ -d "$path" ] && [ "$(jget item < "$path/.flow/claim.json")" = "$t2" ]
printf 'x\n' > "$path/keep.txt"
printf '{"worktree_path":"%s","cwd":"%s"}' "$path" "$PWD" | "$P/hooks/worktree-remove.sh" >/dev/null 2>&1; code=$?
check "WorktreeRemove keeps a dirty worktree (exit 3)" [ "$code" -eq 3 ] && [ -f "$path/keep.txt" ]
rm "$path/keep.txt"
printf '{"worktree_path":"%s","cwd":"%s"}' "$path" "$PWD" | "$P/hooks/worktree-remove.sh" >/dev/null 2>&1; code=$?
check "WorktreeRemove releases a clean worktree" [ "$code" -eq 0 ] && [ ! -f "$path/.flow/claim.json" ]
adhoc="$(printf '{"name":"bold-oak","cwd":"%s"}' "$PWD" | "$P/hooks/worktree-create.sh" 2>/dev/null | tail -1)"
check "WorktreeCreate ad hoc name" [ -d "$adhoc" ] && [ "$(jget item < "$adhoc/.flow/claim.json")" = "adhoc:bold-oak" ]
"$P/scripts/steward.sh" release "$adhoc" --force >/dev/null 2>&1

echo "github adapter (fake gh)"
export FAKE_GH_DIR="$work/gh"; mkdir -p "$FAKE_GH_DIR"; cp "$P/tests/_fake_gh.py" "$FAKE_GH_DIR/"
cat > "$FAKE_GH_DIR/issues.json" <<'JSON'
{"issues": [
  {"number": 10, "title": "Epic", "body": "", "state": "OPEN", "labels": ["epic", "size:L"], "url": "https://gh/10"},
  {"number": 11, "title": "Task one", "body": "## Acceptance\n- x", "state": "OPEN", "labels": ["size:S"], "url": "https://gh/11", "blocked_by": []},
  {"number": 12, "title": "Task two", "body": "", "state": "OPEN", "labels": ["size:M", "status:blocked"], "url": "https://gh/12", "blocked_by": [11]},
  {"number": 13, "title": "Old", "body": "", "state": "CLOSED", "labels": [], "url": "https://gh/13"}
]}
JSON
mkdir -p "$work/bin" && ln -s "$P/tests/fake-gh.sh" "$work/bin/gh"
export PATH="$work/bin:$PATH"
printf 'adapters:\n  default: github\nbase: main\ngithub:\n  repo: acme/widgets\npool:\n  - ../wt-1\n  - ../wt-2\nnotify:\n  desktop: false\n' > .flow/config.yaml
item="$("$P/adapters/github/read.sh" 'gh#11')"
check "gh read"           [ "$(printf '%s' "$item" | jget title)" = "Task one" ] && [ "$(printf '%s' "$item" | jget size)" = "S" ] && [ "$(printf '%s' "$item" | jget kind)" = "task" ]
check "gh read epic kind" [ "$("$P/adapters/github/read.sh" 'gh#10' | jget kind)" = "epic" ]
check "gh list open"      [ "$("$P/adapters/github/list.sh" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = "3" ]
check "gh list-ready excludes blocked" [ "$("$P/adapters/github/list-ready.sh" | python3 -c 'import json,sys; print(",".join(i["id"] for i in json.load(sys.stdin)))')" = "gh#10,gh#11" ]
"$P/adapters/github/write-state.sh" 'gh#11' step=implement worktree=wt-1 profile=task-S attempts=1 last_event="t start" touches=src/**
check "gh labels mirrored" sh -c "grep -q 'issue edit 11 .*--add-label step:implement --add-label wt:wt-1 --add-label flow:task-S' '$FAKE_GH_DIR/calls.log'"
item="$("$P/adapters/github/read.sh" 'gh#11')"
check "gh state round trip" [ "$(printf '%s' "$item" | jget state.step)" = "implement" ] && [ "$(printf '%s' "$item" | jget state.attempts)" = "1" ] && [ "$(printf '%s' "$item" | jget state.worktree)" = "wt-1" ] && [ "$(printf '%s' "$item" | jget state.touches)" = '["src/**"]' ]
"$P/adapters/github/write-state.sh" 'gh#11' step=test gate=none
check "gh label replaced" sh -c "grep -q 'add-label step:test --remove-label step:implement' '$FAKE_GH_DIR/calls.log'"
check "gh one state comment" [ "$(python3 -c 'import json; print(len([c for c in json.load(open("'"$FAKE_GH_DIR"'/issues.json"))["issues"][1]["comments"] if "flow:state" in c["body"]]))')" = "1" ]
"$P/adapters/github/comment.sh" 'gh#11' --body "hello"
"$P/adapters/github/link-pr.sh" 'gh#11' https://gh/pr/5
check "gh link-pr"        [ "$("$P/adapters/github/read.sh" 'gh#11' | jget state.pr)" = "https://gh/pr/5" ]
"$P/adapters/github/close.sh" 'gh#11' --comment done
check "gh close"          [ "$("$P/adapters/github/read.sh" 'gh#11' | jget status)" = "closed" ]
check "gh next.sh end to end" sh -c "'$P/scripts/next.sh' --json | grep -q '\"item\":\"gh#10\"'"
check "cross-tracker blocker: local waits on gh" sh -c "'$P/adapters/local/create.sh' task Cross --blocked-by 'gh#12' >/dev/null && ! '$P/adapters/local/list-ready.sh' | grep -q Cross"

printf '{"issues": [{"number": 20, "title": "Epic", "body": "", "state": "OPEN", "labels": ["epic"], "url": "https://gh/20", "id": 1020, "node": "I_20"}]}' > "$FAKE_GH_DIR/issues.json"
child="$("$P/adapters/github/create.sh" task "Slice one" --size S --parent 'gh#20' --body "## What
x")"
check "gh create returns id" [ "$child" = "gh#21" ]
check "gh create: sub-issue linked, size label, body tail" sh -c "grep -q 'addSubIssue' '$FAKE_GH_DIR/calls.log' && '$P/adapters/github/read.sh' 'gh#21' | grep -q '\"parent\": *\"gh#20\"' && '$P/adapters/github/read.sh' 'gh#21' | grep -q 'size:S'"
child2="$("$P/adapters/github/create.sh" task "Slice two" --blocked-by 'gh#21')"
check "gh create: blocker edge recorded" [ "$("$P/adapters/github/read.sh" "$child2" | jget blocked_by)" = '["gh#21"]' ]
check "gh parent from the body line in list" sh -c "'$P/adapters/github/list.sh' | grep -q '\"parent\": *\"gh#20\"'"

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
check "threads: unresolved only, with ids" [ "$(printf '%s' "$threads" | jget 0.thread_id)" = "T_1" ] && [ "$(printf '%s' "$threads" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = "1" ]
"$P/scripts/comments.sh" reply 90 501 "fixed in abc123"
"$P/scripts/comments.sh" resolve T_1
check "reply and resolve" sh -c "python3 -c \"import json; d=json.load(open('$FAKE_GH_DIR/issues.json')); t=d['threads'][0]; assert t['isResolved'] and 'abc123' in t['comments']['nodes'][1]['body']\""
check "state and ready" sh -c "'$P/scripts/comments.sh' state 90 | grep -q '\"isDraft\": *true' && '$P/scripts/comments.sh' ready 90 && '$P/scripts/comments.sh' state 90 | grep -q '\"isDraft\": *false'"

echo "jobs (fake hosts)"
export HOST_LOG="$work/host.log"; realrepo="$(cd "$repo" && pwd -P)"
for h in claude codex; do printf '#!/bin/sh\nprintf "%%s\\t%%s\\t%%s\\n" "$0" "$PWD" "$*" >> "$HOST_LOG"\n' > "$work/bin/$h"; chmod +x "$work/bin/$h"; done
"$P/adapters/github/write-state.sh" 'gh#21' step=pr && "$P/adapters/github/link-pr.sh" 'gh#21' https://gh/pull/90
"$P/jobs/comments.sh" claude >/dev/null
check "comments job: runs the skill per open PR from the main worktree" sh -c "grep -q 'claude	$realrepo	-p Invoke the flow plugin.s comments skill.*gh#21' '$HOST_LOG' && grep -q 'addressing gh#21' .flow/log/comments.log"
check "comments job: one PR, one run" [ "$(grep -c comments "$HOST_LOG")" = "1" ]
"$P/jobs/comments.sh" codex >/dev/null
check "comments job on codex: exec in the main worktree" sh -c "grep -q 'codex	.*	exec -C $realrepo -s workspace-write' '$HOST_LOG'"
printf 'adapters:\n  default: github\nbase: main\ngithub:\n  repo: acme/widgets\npool:\n  - ../wt-1\n  - ../wt-2\nnotify:\n  desktop: false\njobs:\n  model: haiku\n  effort: low\n' > .flow/config.yaml
"$P/jobs/comments.sh" claude 'gh#21' >/dev/null
check "jobs.model and jobs.effort reach the host" sh -c "grep -q 'gh#21.*--model haiku --effort low' '$HOST_LOG'"
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr']['state']='MERGED'; json.dump(d, open(p,'w'))"
: > "$HOST_LOG"
"$P/jobs/comments.sh" claude >/dev/null
check "comments job: merged PR skipped, quiet" sh -c "[ ! -s '$HOST_LOG' ] && grep -q 'quiet: no open PR' .flow/log/comments.log"
mkdir -p .flow/log/comments.lock && echo $$ > .flow/log/comments.lock/pid
check "job lock: live pid skips"  sh -c "'$P/jobs/comments.sh' claude | grep -q 'skipped: run $$ still going'"
echo 999999 > .flow/log/comments.lock/pid
check "job lock: stale pid runs" sh -c "'$P/jobs/comments.sh' claude | grep -q 'quiet: no open PR' && [ ! -d .flow/log/comments.lock ]"
check "job: unknown host refused" sh -c "! '$P/jobs/comments.sh' vim 2>/dev/null"
home2="$work/home2"; mkdir -p "$home2"
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\nnotify:\n  desktop: false\n' > "$home2/config.yaml"
check "next job: nothing ready is quiet" sh -c "FLOW_HOME='$home2' '$P/jobs/next.sh' claude | grep -q 'quiet: nothing ready'"
check "retro job: no lessons is quiet" sh -c "FLOW_HOME='$home2' '$P/jobs/retro.sh' claude | grep -q 'quiet: 0 new'"
FLOW_HOME="$home2" "$P/scripts/lesson.sh" review-blocker 'local:task/9' "Magic number" --rule N-06 >/dev/null
FLOW_HOME="$home2" "$P/scripts/lesson.sh" escalation 'local:task/9' "verify failed 3 times" >/dev/null
: > "$HOST_LOG"
check "retro job: new lessons run the skill" sh -c "FLOW_HOME='$home2' '$P/jobs/retro.sh' claude | grep -q 'running over 2 new' && grep -q 'retro skill.*Read the 2 lessons.*2 lines, 0 read before' '$HOST_LOG'"
printf '%s\t2\t1\t1\n' "$(date -u +%FT%TZ)" > "$home2/retros.log"
check "retro job: retros.log marks the lessons read" sh -c "FLOW_HOME='$home2' '$P/jobs/retro.sh' claude --min-lessons 1 | grep -q 'quiet: 0 new'"

echo "new item and pool growth"
mkdir -p "$work/grow" && cd "$work/grow" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t
printf 'hi\n' > README.md && printf 'local\n' > .gitignore && printf 'secret\n' > local && git add -A && git commit -qm init
mkdir -p .flow
printf 'adapters:\n  default: local\nbase: main\npool:\n  # - ../app-wt-1\npool_max: 2\nworktree_copy:\n  - local\nworktree_setup:\n  - printf ran > setup.txt\nnotify:\n  desktop: false\n' > .flow/config.yaml
n1="$(printf '## Problem\nx\n## Acceptance\n- [ ] y\n' | "$P/scripts/new.sh" task "Grow the pool" --size S --body-file -)"
check "new: creates through the kind's adapter" [ "$n1" = "local:task/1" ] && grep -q '^## Acceptance' .flow/items/task/1.md
check "new: bad kind refused" sh -c "! '$P/scripts/new.sh' story 'x' 2>/dev/null"
check "new: empty title refused" sh -c "! '$P/scripts/new.sh' task '' 2>/dev/null"
g1="$("$P/scripts/steward.sh" claim "$n1" 2>/dev/null)"
check "claim grows an empty pool" [ "$g1" = "$(cd ../app-wt-1 && pwd -P)" ] && [ "$(git -C "$g1" symbolic-ref --short HEAD)" = "flow/local-task-1" ]
check "the pool entry is appended, placeholder dropped" [ "$(yaml_get .flow/config.yaml pool)" = ../app-wt-1 ] && ! grep -q '# - ../app-wt-1' .flow/config.yaml && [ "$(yaml_get .flow/config.yaml pool_max)" = 2 ]
check "worktree_copy and worktree_setup ran" [ "$(cat "$g1/local")" = secret ] && [ "$(cat "$g1/setup.txt")" = ran ]
n2="$("$P/scripts/new.sh" bug "Second")"
g2="$("$P/scripts/steward.sh" claim "$n2" 2>/dev/null)"
check "a second claim grows again, named after the last entry" [ "$g2" = "$(cd ../app-wt-2 && pwd -P)" ] && [ "$(yaml_get .flow/config.yaml pool | wc -l | tr -d ' ')" = 2 ]
n3="$("$P/scripts/new.sh" task "Third")"
"$P/scripts/steward.sh" claim "$n3" >/dev/null 2>&1; code=$?
check "at pool_max the claim fails (exit 3)" [ "$code" -eq 3 ] && [ ! -d ../app-wt-3 ]
rm "$g2/setup.txt"
check "setup re-runs on demand" sh -c "'$P/scripts/steward.sh' setup '$g2' >/dev/null && [ -f '$g2/setup.txt' ]"
"$P/scripts/steward.sh" add >/dev/null 2>&1
check "add without a path takes the next name" [ -d ../app-wt-3 ] && [ "$(yaml_get .flow/config.yaml pool | tail -1)" = ../app-wt-3 ]
cd "$repo"

# --- init: stamp, guard, session-start nudge (on a copy of the plugin, so the plugin can change). The fake gh stays on PATH; init tolerates it.
plugin_copy="$work/plugin"; cp -R "$P" "$plugin_copy"; rm -rf "$plugin_copy/evals/results"
init="$plugin_copy/skills/init/scripts/init.sh"; start="$plugin_copy/hooks/session-start.sh"
mkdir -p "$work/fresh" && cd "$work/fresh" && git init -q -b main && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init
check "init: a fresh install writes the stamp" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' >/dev/null && grep -q '^source	' .flow/stamp && grep -q '	.codex/rules/flow.rules' .flow/stamp && ! grep -q 'notify.sh' .flow/stamp"
check "init: --check is clean after install" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'up to date'"
check "session-start: silent when the stamp matches" sh -c "[ -z \"\$(echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start')\" ]"
printf '# mine\n' >> .flow/notify.sh
check "init: a wrapper is replaced without a guard" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' >/dev/null && ! grep -q '# mine' .flow/notify.sh"
printf '# mine\n' >> .codex/rules/flow.rules
check "init: --check names a hand edit" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'edited by hand: .codex/rules/flow.rules'"
check "init: refuses to replace a hand edit (exit 1, file kept)" sh -c "! FLOW_PLUGIN='$plugin_copy' '$init' >/dev/null && grep -q '# mine' .codex/rules/flow.rules"
check "init: --force replaces it" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' --force >/dev/null && ! grep -q '# mine' .codex/rules/flow.rules && FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'up to date'"
printf '\n# changed\n' >> "$plugin_copy/templates/flow.rules"
check "session-start: nudges when the plugin changed" sh -c "echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start' | grep -q 'behind flow v' && echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start' | grep -q 'drift: .codex/rules/flow.rules'"
check "init: refresh brings the stamp back in step" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' >/dev/null && [ -z \"\$(echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start')\" ]"
rm .flow/stamp
check "session-start: no stamp asks for one init" sh -c "echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start' | grep -q 'no install stamp'"
printf 'adapters:\n  default: local\nbase: main\npool:\npool_max: 0\n' > .flow/config.yaml
check "init: --check flags an empty pool with pool_max 0 as a gap" sh -c "! FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'up to date' && FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'gap: .flow/config.yaml: the pool is empty'"
check "init: lists the gap after an install" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' | grep -q 'Gaps'"
mkdir -p "$work/plain" && cd "$work/plain" && git init -q
check "session-start: silent in a project without the flow" sh -c "[ -z \"\$(echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start')\" ]"

[ "$fails" -eq 0 ] && { echo "flow: ok"; exit 0; }
echo "flow: $fails failed"; exit 1
