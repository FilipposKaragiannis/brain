#!/bin/sh
# Tests for the flow plugin: config parsing, both adapters (GitHub through a fake gh), the
# steward, next/advance, gates, re-sizing, overlap, the board and the worktree hooks. Builds a
# throwaway repo with a two-worktree pool. Run from anywhere. Exit 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$P"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# No test reaches the network, the desktop or a real agent. The owner's shell may export
# FLOW_SLACK_WEBHOOK, so it is cleared, and these tools are stubs that log to $work/offline.log.
# A test that needs one of them puts its own fake earlier in PATH.
unset FLOW_SLACK_WEBHOOK
mkdir -p "$work/offline"
for tool in curl wget gh osascript notify-send claude codex launchctl; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/offline.log"\n' "$tool" "$work" > "$work/offline/$tool"
  chmod +x "$work/offline/$tool"
done
PATH="$work/offline:$PATH"; export PATH
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { # check <name> <condition command...>
  name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}
check_all() { # check_all <name> '<condition>': the condition is shell text run whole, so every
  # part of an && or || chain or a pipe is tested, not only the part before the first operator.
  name="$1"; shift
  if eval "$1" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
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
check_all "slug"              '[ "$(item_slug '\''gh#12'\'')" = "gh-12" ] && [ "$(item_slug local:bug/3)" = "local-bug-3" ]'
check_all "profile select"    '[ "$(profile_select task S)" = "task-S" ] && [ "$(profile_select bug M)" = "bugfix" ] && [ "$(profile_select task XL)" = "task-L" ]'

echo "local adapter"
t1="$("$P/adapters/local/create.sh" task "First task" --size S --body "Do it.")"
b1="$("$P/adapters/local/create.sh" bug "A bug" --blocked-by "$t1")"
t2="$("$P/adapters/local/create.sh" task "Medium task")"
check_all "create ids"        '[ "$t1" = "local:task/1" ] && [ "$b1" = "local:bug/1" ] && [ "$t2" = "local:task/2" ]'
check "read title"        [ "$("$P/adapters/local/read.sh" "$t1" | jget title)" = "First task" ]
check "read default size" [ "$("$P/adapters/local/read.sh" "$t2" | jget size)" = "" ]
"$P/adapters/local/write-state.sh" "$t1" step=implement attempts=2 touches=src/a/**,docs/*
check_all "write-state"       '[ "$("$P/adapters/local/read.sh" "$t1" | jget state.step)" = "implement" ] && [ "$("$P/adapters/local/read.sh" "$t1" | jget state.touches)" = '\''["src/a/**", "docs/*"]'\'' ]'
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
check_all "release refuses dirty (exit 3)" '[ "$code" -eq 3 ] && [ -f "$w1/.flow/claim.json" ]'
rm "$w1/dirty.txt"
check "release clean"     "$P/scripts/steward.sh" release "$t1"
check_all "released: detached, no claim, tracker cleared" '[ ! -f "$w1/.flow/claim.json" ] && ! git -C "$w1" symbolic-ref -q HEAD && [ -z "$("$P/adapters/local/read.sh" "$t1" | jget state.worktree)" ]'
check "pool table"        sh -c "'$P/scripts/steward.sh' pool | grep -q 'wt-2.*free'"

echo "next and advance"
out="$("$P/scripts/next.sh" --json)"; code=$?
check_all "next picks first ready" '[ "$code" -eq 0 ] && [ "$(printf '\''%s'\'' "$out" | jget item)" = "$t1" ] && [ "$(printf '\''%s'\'' "$out" | jget step)" = "implement" ]'
brief="$(printf '%s' "$out" | jget brief)"; reports="$(printf '%s' "$out" | jget reports)"
check_all "brief written in the worktree" '[ -f "$brief" ] && grep -q '\''cd "'\'' "$brief" && grep -q '\''implement.json'\'' "$brief"'
check "run recorded"      [ -f .flow/runs/local-task-1.json ]
check_all "state step"        '[ "$("$P/adapters/local/read.sh" "$t1" | jget state.step)" = "implement" ] && [ "$("$P/adapters/local/read.sh" "$t1" | jget state.profile)" = "task-S" ]'
"$P/scripts/next.sh" "$t1" >/dev/null 2>&1; code=$?
check "second next on a running item: exit 7" [ "$code" -eq 7 ]
out2="$("$P/scripts/next.sh" --json)"
check_all "next picks the other item in wt-2" '[ "$(printf '\''%s'\'' "$out2" | jget item)" = "$t2" ] && [ "$(printf '\''%s'\'' "$out2" | jget step)" = "design" ] && [ "$(basename "$(printf '\''%s'\'' "$out2" | jget worktree)")" = "wt-2" ]'
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
check_all "fail: attempt 1, step test stays" '[ "$("$P/adapters/local/read.sh" "$t1" | jget state.attempts)" = "1" ] && [ "$("$P/adapters/local/read.sh" "$t1" | jget state.step)" = "test" ]'
"$P/scripts/advance.sh" "$t1" --status fail --summary "red again" >/dev/null; "$P/scripts/next.sh" "$t1" >/dev/null
"$P/scripts/advance.sh" "$t1" --status fail --summary "still red" >/dev/null 2>&1; code=$?
check_all "third fail: escalation gate (exit 4)" '[ "$code" -eq 4 ] && [ "$("$P/adapters/local/read.sh" "$t1" | jget state.gate)" = "escalation" ] && [ -f .flow/gates/local-task-1.json ]'
"$P/scripts/next.sh" "$t1" >/dev/null 2>&1; code=$?
check "next at a gate: exit 4" [ "$code" -eq 4 ]
check "gate list"         sh -c "'$P/scripts/gate.sh' list | grep -q escalation"
"$P/scripts/gate.sh" clear "$t1" "fixed" >/dev/null
check_all "gate cleared"      '[ "$("$P/adapters/local/read.sh" "$t1" | jget state.gate)" = "none" ] && [ ! -f .flow/gates/local-task-1.json ] && [ "$("$P/adapters/local/read.sh" "$t1" | jget state.attempts)" = "0" ]'
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
check_all "pr done -> merge gate (exit 4), step done" '[ "$code" -eq 4 ] && [ "$("$P/adapters/local/read.sh" "$t1" | jget state.gate)" = "merge" ] && [ "$("$P/adapters/local/read.sh" "$t1" | jget state.step)" = "done" ]'
"$P/scripts/gate.sh" clear "$t1" merged >/dev/null
"$P/scripts/next.sh" "$t1" >/dev/null 2>&1; code=$?
check "next on a done item: exit 6" [ "$code" -eq 6 ]

echo "re-size and gates"
r2="$(printf '%s' "$out2" | jget reports)"
printf '{"status":"done","size":"L","summary":"bigger"}\n' > "$r2/design.json"
"$P/scripts/advance.sh" "$t2" >/dev/null 2>&1; code=$?
check_all "M -> L stops at plan-approval" '[ "$code" -eq 4 ] && [ "$("$P/adapters/local/read.sh" "$t2" | jget state.gate)" = "plan-approval" ] && [ "$("$P/adapters/local/read.sh" "$t2" | jget state.size)" = "L" ]'
"$P/scripts/gate.sh" clear "$t2" "replanned" >/dev/null
"$P/scripts/next.sh" "$t2" >/dev/null; printf '{"status":"done"}\n' > "$r2/design.json"
"$P/scripts/advance.sh" "$t2" >/dev/null 2>&1
check_all "L profile after re-size" '[ "$("$P/adapters/local/read.sh" "$t2" | jget state.profile)" = "task-L" ] && [ "$("$P/adapters/local/read.sh" "$t2" | jget state.step)" = "plan" ]'
"$P/scripts/next.sh" "$t2" >/dev/null; printf '{"status":"done","summary":"planned"}\n' > "$r2/plan.json"
"$P/scripts/advance.sh" "$t2" >/dev/null 2>&1; code=$?
check_all "plan -> plan-approval gate, step implement" '[ "$code" -eq 4 ] && [ "$("$P/adapters/local/read.sh" "$t2" | jget state.step)" = "implement" ]'
"$P/scripts/gate.sh" clear "$t2" approved >/dev/null
"$P/scripts/next.sh" "$t2" >/dev/null
printf '{"status":"gate","gate":"ambiguity","message":"A or B?"}\n' > "$r2/implement.json"
"$P/scripts/advance.sh" "$t2" >/dev/null 2>&1; code=$?
check_all "agent raises ambiguity" '[ "$code" -eq 4 ] && [ "$("$P/adapters/local/read.sh" "$t2" | jget state.gate)" = "ambiguity" ] && grep -q '\''A or B'\'' .flow/gates/local-task-2.json'
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
check "verify fails on the broken gate (exit 1)" sh -c '[ "$1" -eq 1 ] && [ "$2" = fail ]' _ "$code" "$(jget status < "$rv/verify.json" 2>/dev/null)"
check "verify checks: build, format, tests, mutation signal, two gates" [ "$(python3 -c 'import json; cs=json.load(open("'"$rv"'/verify.json"))["checks"]; print(",".join(c["name"]+":"+c["status"] for c in cs))')" = "build:pass,format:pass,tests:pass,mutation:signal,gate determinism:pass,gate harness:fail" ]
check "verify summary carries the error text" sh -c "grep -q 'harness broke' '$rv/verify.json'"
check "verify feel_test from changed ui file" [ "$(jget feel_test < "$rv/verify.json")" = "true" ]
check "verify.md twin" sh -c "grep -q 'Feel-test needed' '$rv/verify.md' && grep -q '| build | pass' '$rv/verify.md'"
echo "verify: the report is never empty"
# The CI flake: a short head sha of digits with a leading zero went into the report as a number
# (0123456 is not JSON), the pretty-print failed and the redirect left verify.json empty.
# Find such a commit object (same tree, the head as parent) and make it the worktree's head.
whead="$(git -C "$wv" rev-parse HEAD)"
zsha="$(python3 - "$(git -C "$wv" rev-parse 'HEAD^{tree}')" "$whead" <<'PY'
import hashlib, re, sys
tree, parent = sys.argv[1:3]
for n in range(10 ** 6):
    body = ("tree %s\nparent %s\nauthor t <t@t> 0 +0000\ncommitter t <t@t> 0 +0000\n\nzero %d\n" % (tree, parent, n)).encode()
    sha = hashlib.sha1(b"commit %d\0" % len(body) + body).hexdigest()
    if re.match(r"0[0-9]{11}", sha):
        sys.stdout.buffer.write(body); break
PY
)"
zsha="$(printf '%s\n' "$zsha" | git -C "$wv" hash-object -t commit -w --stdin)"
git -C "$wv" reset -q "$zsha"
(cd "$wv" && "$P/scripts/verify.sh" "$v1" >/dev/null 2>&1); code=$?
zhead="$(jget head < "$rv/verify.json" 2>/dev/null)"
check "a head sha of digits with a leading zero: the report parses, head is the string" sh -c '[ "$1" -eq 1 ] && [ "$2" = "$3" ]' _ "$code" "$zhead" "$(git -C "$wv" rev-parse --short HEAD)"
git -C "$wv" reset -q "$whead"
# A gate whose output is hostile to hand-built JSON: quotes, backslashes, newlines, control
# characters, a byte that is not UTF-8, a summary of digits only and a very long line.
printf '%s\n' '#!/bin/sh' "printf 'say \"hi\" and C:\\\\dir\\\\n\\n\\tline\\001two\\033[0m\\n\\377\\376 bad bytes\\n'" "python3 -c 'print(\"y\" * 5000)'" 'echo "$1"; exit 1' > "$work/noisy.sh"
cp .flow/config.yaml "$work/config.keep"
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\ngates:\n  noisy: '"'"'sh %s/noisy.sh last'"'"'\n  digits: '"'"'sh -c "echo 007; exit 1"'"'"'\nnotify:\n  desktop: false\n' "$work" > .flow/config.yaml
(cd "$wv" && "$P/scripts/verify.sh" "$v1" >/dev/null 2>"$work/verify.err"); code=$?
noisy="$(python3 -c 'import json,sys; c=[c for c in json.load(open(sys.argv[1]))["checks"] if c["name"]=="gate noisy"][0]; print(c["status"], len(c["summary"]) <= 400, "\"hi\"" in c["summary"], "C:\\dir" in c["summary"])' "$rv/verify.json" 2>&1)"
check "hostile output: the report parses and the summary keeps quotes and backslashes, cut to 400" sh -c '[ "$1" -eq 1 ] && [ "$2" = "fail True True True" ]' _ "$code" "$noisy"
check "a summary of digits stays a string" [ "$(python3 -c 'import json,sys; print(repr([c for c in json.load(open(sys.argv[1]))["checks"] if c["name"]=="gate digits"][0]["summary"]))' "$rv/verify.json" 2>&1)" = "'007'" ]
check "hostile output: verify.md has the row, one line" sh -c '[ "$(grep -c "^| gate noisy | fail |" "$1")" = 1 ]' _ "$rv/verify.md"
check "hostile output: nothing on stderr" [ ! -s "$work/verify.err" ]
osc="$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import _verify_report as v
print(v.summary("see \x1b]8;;https://ci/run/7\x07the run\x1b]8;;\x07 and \x1b]8;id=1;https://ci/log\x1b\\the log\x1b]8;;\x1b\\ \x1b[31mred\x1b[0m"))' "$P/scripts" 2>&1)"
check "a terminal hyperlink (OSC 8, either terminator) leaves only its text in the summary" [ "$osc" = "see the run and the log red" ]
# dash runs no EXIT trap on a signal: a verify stopped by TERM must still remove its temp files.
if command -v dash >/dev/null 2>&1; then
  mkdir -p "$work/vtmp"
  printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\ngates:\n  slow: sleep 2\nnotify:\n  desktop: false\n' > .flow/config.yaml
  (cd "$wv" && TMPDIR="$work/vtmp" exec dash "$P/scripts/verify.sh" "$v1" >/dev/null 2>&1) & vp=$!
  n=0; while [ -z "$(ls -A "$work/vtmp")" ] && [ "$n" -lt 100 ]; do n=$((n + 1)); sleep 0.1; done
  kill -TERM "$vp" 2>/dev/null; wait "$vp"
  check_all "verify under dash stopped by TERM leaves no temp file" '[ "$n" -lt 100 ] && [ -z "$(ls -A "$work/vtmp")" ]'
fi
# The write is atomic: a reader polling verify.json while verify runs never sees it empty, and
# no temp file is left behind.
: > "$work/reads.bad"
(for _ in 1 2 3; do (cd "$wv" && "$P/scripts/verify.sh" "$v1" >/dev/null 2>&1); done; : > "$work/verify.done") &
vpid=$!
while [ ! -f "$work/verify.done" ]; do [ -e "$rv/verify.json" ] && [ ! -s "$rv/verify.json" ] && echo empty >> "$work/reads.bad"; done
wait "$vpid"; rm -f "$work/verify.done"
check "a reader never sees verify.json empty" [ ! -s "$work/reads.bad" ]
check "no temp file left in the reports folder" [ -z "$(ls -A "$rv" | grep -i -e tmp -e '^\.verify')" ]
# A report that cannot be built fails loudly: a message on stderr, a minimal valid report with
# status fail and the cause as a check summary, a non-zero exit.
mkdir -p "$work/badpy"
printf '#!/bin/sh\ncase "$*" in *_verify_report.py*) echo "boom: report builder broke" >&2; exit 1 ;; esac\nexec %s "$@"\n' "$(command -v python3)" > "$work/badpy/python3"; chmod +x "$work/badpy/python3"
(cd "$wv" && PATH="$work/badpy:$PATH" "$P/scripts/verify.sh" "$v1" >/dev/null 2>"$work/verify.err"); code=$?
bad="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["status"], any("boom" in c["summary"] for c in d["checks"]))' "$rv/verify.json" 2>&1)"
check "a report that cannot be built: exit non-zero, the cause on stderr" sh -c '[ "$1" -ne 0 ] && grep -q "boom" "$2"' _ "$code" "$work/verify.err"
check "a report that cannot be built: a valid report, status fail, the cause as a summary" [ "$bad" = "fail True" ]
check "a report that cannot be built: verify.md says so" grep -q "boom" "$rv/verify.md"
cp "$work/config.keep" .flow/config.yaml
echo "verify: gate paths and the mutation switch"
cat > .flow/config.yaml <<'YAML'
adapters:
  default: local
base: main
pool:
  - ../wt-1
  - ../wt-2
gates:
  flat: 'sh -c "exit 0"'
  server-only:
    command: 'sh -c "exit 1"'
    paths: [server/**, db/*.sql]
  tools:
    command: 'sh -c "exit 0"'
    paths:
      - "*.sh"
notify:
  desktop: false
YAML
(cd "$wv" && "$P/scripts/verify.sh" "$v1" >/dev/null 2>&1); code=$?
vchecks() { python3 -c 'import json; cs=json.load(open("'"$rv"'/verify.json"))["checks"]; print(",".join(c["name"]+":"+c["status"] for c in cs))'; }
check "gate with paths: skipped when no changed file matches, runs when one does" sh -c '[ "$1" = "gate flat:pass,gate server-only:skipped,gate tools:pass" ] && [ "$2" -eq 0 ]' _ "$(vchecks 2>/dev/null | sed 's/.*mutation:[a-z]*,//')" "$code"
check "a skipped gate says why" sh -c "grep -q 'no changed file under its paths' '$rv/verify.json'"
mkdir -p "$wv/server"; printf 'x\n' > "$wv/server/a.txt"
(cd "$wv" && "$P/scripts/verify.sh" "$v1" >/dev/null 2>&1); code=$?
check "gate with paths: runs and fails once a changed file matches" sh -c '[ "$1" -eq 1 ] && [ "$2" = "gate server-only:fail" ]' _ "$code" "$(vchecks 2>/dev/null | grep -o 'gate server-only:[a-z]*')"
std="$wv/.standards/config.json"
setstd() { python3 - "$std" "$1" "$2" <<'PY'
import json, sys
p = sys.argv[1]; c = json.load(open(p)); c[sys.argv[2]] = sys.argv[3]; json.dump(c, open(p, "w"))
PY
}
setstd mutation ""
(cd "$wv" && "$P/scripts/verify.sh" "$v1" >/dev/null 2>&1)
check "empty mutation is the off switch: a skipped check, never a fail" [ "$(vchecks | grep -o 'mutation:[a-z]*')" = "mutation:skipped" ]
setstd mutation "sh -c 'echo MUTATING {files}; exit 1'"
(cd "$wv" && "$P/scripts/verify.sh" "$v1" >/dev/null 2>&1)
vm="$(vchecks | grep -o 'mutation:[a-z]*')"
check "mutation with {files} runs on the changed source files only, as a signal" sh -c "[ '$vm' = mutation:signal ] && grep -q 'MUTATING tool.sh' '$rv/verify.log' && ! grep -q 'MUTATING .*panel.txt' '$rv/verify.log'"
python3 - "$std" <<'PY'
import json, sys
c = json.load(open(sys.argv[1])); c["languages"] = [{"name": "z", "extensions": [".zzz"], "format": [{"prefix": "", "command": "true"}]}]; json.dump(c, open(sys.argv[1], "w"))
PY
(cd "$wv" && "$P/scripts/verify.sh" "$v1" >/dev/null 2>&1)
check "mutation with {files} is skipped when no changed source file applies" [ "$(vchecks | grep -o 'mutation:[a-z]*')" = "mutation:skipped" ]
git -C "$wv" checkout -q .standards/config.json; rm -r "$wv/server"
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\ngates:\n  determinism: '"'"'sh -c "exit 0"'"'"'\nfeel_test_paths:\n  - ui/**\nnotify:\n  desktop: false\n' > .flow/config.yaml
for s in implement test review; do printf '{"status":"done"}\n' > "$rv/$s.json"; "$P/scripts/advance.sh" "$v1" >/dev/null 2>&1; "$P/scripts/next.sh" "$v1" >/dev/null 2>&1; done
(cd "$wv" && "$P/scripts/verify.sh" "$v1" >/dev/null 2>&1); code=$?
check "verify passes without the broken gate" sh -c '[ "$1" -eq 0 ] && [ "$2" = pass ]' _ "$code" "$(jget status < "$rv/verify.json" 2>/dev/null)"
"$P/scripts/advance.sh" "$v1" >/dev/null 2>&1; code=$?
check "passing verify with feel_test raises the feel-test gate, step pr" sh -c '[ "$1" -eq 4 ] && [ "$2" = feel-test ] && [ "$3" = pr ]' _ "$code" "$("$P/adapters/local/read.sh" "$v1" | jget state.gate)" "$("$P/adapters/local/read.sh" "$v1" | jget state.step)"
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
check_all "WorktreeCreate claims a pool path" '[ -d "$path" ] && [ "$(jget item < "$path/.flow/claim.json")" = "$t2" ]'
printf 'x\n' > "$path/keep.txt"
printf '{"worktree_path":"%s","cwd":"%s"}' "$path" "$PWD" | "$P/hooks/worktree-remove.sh" >/dev/null 2>&1; code=$?
check_all "WorktreeRemove keeps a dirty worktree (exit 3)" '[ "$code" -eq 3 ] && [ -f "$path/keep.txt" ]'
rm "$path/keep.txt"
printf '{"worktree_path":"%s","cwd":"%s"}' "$path" "$PWD" | "$P/hooks/worktree-remove.sh" >/dev/null 2>&1; code=$?
check_all "WorktreeRemove releases a clean worktree" '[ "$code" -eq 0 ] && [ ! -f "$path/.flow/claim.json" ]'
adhoc="$(printf '{"name":"bold-oak","cwd":"%s"}' "$PWD" | "$P/hooks/worktree-create.sh" 2>/dev/null | tail -1)"
check_all "WorktreeCreate ad hoc name" '[ -d "$adhoc" ] && [ "$(jget item < "$adhoc/.flow/claim.json")" = "adhoc:bold-oak" ]'
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
check_all "gh read"           '[ "$(printf '\''%s'\'' "$item" | jget title)" = "Task one" ] && [ "$(printf '\''%s'\'' "$item" | jget size)" = "S" ] && [ "$(printf '\''%s'\'' "$item" | jget kind)" = "task" ]'
check "gh read epic kind" [ "$("$P/adapters/github/read.sh" 'gh#10' | jget kind)" = "epic" ]
check "gh list open"      [ "$("$P/adapters/github/list.sh" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = "3" ]
check "gh list-ready excludes blocked" [ "$("$P/adapters/github/list-ready.sh" | python3 -c 'import json,sys; print(",".join(i["id"] for i in json.load(sys.stdin)))')" = "gh#10,gh#11" ]
"$P/adapters/github/write-state.sh" 'gh#11' step=implement worktree=wt-1 profile=task-S attempts=1 last_event="t start" touches=src/**
check "gh labels mirrored" sh -c "grep -q 'issue edit 11 .*--add-label step:implement --add-label wt:wt-1 --add-label flow:task-S' '$FAKE_GH_DIR/calls.log'"
item="$("$P/adapters/github/read.sh" 'gh#11')"
check_all "gh state round trip" '[ "$(printf '\''%s'\'' "$item" | jget state.step)" = "implement" ] && [ "$(printf '\''%s'\'' "$item" | jget state.attempts)" = "1" ] && [ "$(printf '\''%s'\'' "$item" | jget state.worktree)" = "wt-1" ] && [ "$(printf '\''%s'\'' "$item" | jget state.touches)" = '\''["src/**"]'\'' ]'
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
  priority_order: [P0, P1, P2, P3]
  ready_needs: [priority, size]
  project: 1
pool:
  - ../wt-1
  - ../wt-2
notify:
  desktop: false
YAML
"$P/adapters/github/list.sh" | python3 -c 'import json,sys; [print("%s %s %s %s %s" % (i["id"], i["kind"], i["size"] or "-", i["priority"] or "-", ",".join(i["needs"]) or "-")) for i in json.load(sys.stdin)]' > "$work/ghlist"
check "gh type picks the kind: Epic epic, Bug bug, Feature task" sh -c "'$P/adapters/github/list.sh' | python3 -c 'import json,sys; k={i[\"id\"]:i[\"kind\"] for i in json.load(sys.stdin)}; assert (k[\"gh#30\"],k[\"gh#32\"],k[\"gh#31\"])==(\"epic\",\"bug\",\"task\")'"
check "gh size and priority come from the issue fields" sh -c "'$P/adapters/github/read.sh' 'gh#32' | python3 -c 'import json,sys; i=json.load(sys.stdin); assert (i[\"size\"],i[\"priority\"],i[\"rank\"])==(\"M\",\"P0\",0)'"
check "gh a Parent: line with a colon names the parent" [ "$("$P/adapters/github/read.sh" 'gh#31' | jget parent)" = "gh#30" ]
check "gh an unstarted item lists the fields it lacks" sh -c "grep -qx 'gh#33 task S - priority' '$work/ghlist' && grep -qx 'gh#34 task - P1 size' '$work/ghlist'"
check "gh an epic needs no size" grep -qx 'gh#30 epic - P1 -' "$work/ghlist"
check "gh a started item needs nothing" grep -qx 'gh#36 task S P2 -' "$work/ghlist"
check "gh ready: missing fields, blockers, gates and open sub-issues are out; priority orders the rest" [ "$("$P/adapters/github/list-ready.sh" | python3 -c 'import json,sys; print(",".join(i["id"] for i in json.load(sys.stdin)))')" = "gh#32,gh#30,gh#31,gh#36" ]
check "gh list pages through every issue" [ "$(FLOW_GH_PAGE=2 "$P/adapters/github/list.sh" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = "11" ]
check "gh list stops at the limit and says so" sh -c "[ \"\$('$P/adapters/github/list.sh' --limit 3 2>'$work/limit.err' | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')\" = 3 ] && grep -q 'github.limit 3' '$work/limit.err'"
: > "$FAKE_GH_DIR/calls.log"
"$P/adapters/github/sync.sh" > "$work/sync.out"
status_of() { python3 -c "import json; print(next(i.get('project_status','') for i in json.load(open('$FAKE_GH_DIR/issues.json'))['issues'] if i['number']==$1))"; }
check "gh sync: triaged and unblocked items are Ready" [ "$(status_of 30)$(status_of 32)" = "ReadyReady" ]
check "gh sync: a missing field or an open blocker is Backlog" [ "$(status_of 33)$(status_of 34)$(status_of 35)" = "BacklogBacklogBacklog" ]
check "gh sync: a started step is In progress, a gate Needs you, the merge gate In review" [ "$(status_of 36)|$(status_of 37)|$(status_of 38)" = "In progress|Needs you|In review" ]
check "gh sync: a card already at its status costs no write" sh -c "! grep -q 'i=PI_31' '$FAKE_GH_DIR/calls.log' && ! grep -q '^gh#31' '$work/sync.out'"
check "gh sync: a card missing from the project is added" sh -c "grep -q addProjectV2ItemById '$FAKE_GH_DIR/calls.log'"
check "gh sync: an item with open sub-issues is In progress" [ "$(status_of 39)" = "In progress" ]
check "gh sync twice moves nothing" [ -z "$("$P/adapters/github/sync.sh")" ]
: > "$FAKE_GH_DIR/calls.log"
"$P/adapters/github/write-state.sh" 'gh#33' size=L gate=ambiguity
check "gh write-state: size goes to the field, not a label" sh -c "[ \"\$('$P/adapters/github/read.sh' 'gh#33' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"size\"])')\" = L ] && ! grep -q 'size:L' '$FAKE_GH_DIR/calls.log'"
check "gh write-state moves the card" [ "$(status_of 33)" = "Needs you" ]
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
check "gh create: a child left without the priority ready_needs asks for is said" grep -q 'has no priority and github.ready_needs asks for one' "$work/orphan.err"
check "gh vocabulary: the issue types and the area options" sh -c "'$P/adapters/github/vocabulary.sh' | python3 -c 'import json,sys; v=json.load(sys.stdin); assert \"Chore\" in v[\"types\"] and v[\"areas\"]==[\"Bots\",\"Debugging & Observability\"], v'"
picked="$("$P/scripts/next.sh" --json)"
check "gh next picks the highest priority" [ "$(printf '%s' "$picked" | jget item)" = "gh#32" ]
rm -f .flow/runs/gh-32.json; "$P/scripts/steward.sh" release "$(printf '%s' "$picked" | jget worktree)" --force >/dev/null 2>&1
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); [i.update(state='CLOSED') for i in d['issues'] if i['number']==40]; json.dump(d,open(p,'w'))"
check "gh an epic is ready again once its sub-issues close" sh -c "'$P/adapters/github/list-ready.sh' | grep -q '\"gh#39\"'"
"$P/scripts/gate.sh" raise 'gh#37' ambiguity "1. Visual only?
   Recommended: yes." >/dev/null 2>&1
printf '/answer 1. no, let it touch the ball' | FAKE_GH_USER=stranger gh issue comment 37 -R acme/widgets --body-file - >/dev/null
printf 'thinking about it' | gh issue comment 37 -R acme/widgets --body-file - >/dev/null
printf '/answer 1. no, keep it visual' | gh issue comment 37 -R acme/widgets --body-file - >/dev/null
check "answers: an /answer from the owner after the gate clears it" [ "$("$P/adapters/github/answers.sh")" = "gh#37" ]
check "answers: the owner's words, not a stranger's, and the question stay in the state" sh -c "'$P/adapters/github/read.sh' 'gh#37' | python3 -c 'import json,sys; s=json.load(sys.stdin)[\"state\"]; assert (s[\"gate\"],s[\"answer\"],s[\"answered\"])==(\"none\",\"1. no, keep it visual\",\"ambiguity\") and \"Visual only?\" in s[\"asked\"]'"
check "answers: the answer gets a +1 and a second pass finds nothing" sh -c "grep -q '\"content\": \"+1\"' '$FAKE_GH_DIR/issues.json' && [ -z \"\$('$P/adapters/github/answers.sh')\" ]"
picked="$("$P/scripts/next.sh" 'gh#37' --json)"; brief="$(printf '%s' "$picked" | jget brief)"
check "the next brief carries the owner's answer and the question" sh -c "grep -q \"The owner's answer to the last gate (ambiguity)\" '$brief' && grep -q 'Answer: 1. no, keep it visual' '$brief' && grep -q 'Visual only?' '$brief'"
rm -f .flow/runs/gh-37.json; "$P/scripts/steward.sh" release "$(printf '%s' "$picked" | jget worktree)" --force >/dev/null 2>&1
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
check "slack: a link that is not https stays out of the fallback" sh -c "python3 -I '$P/scripts/_slack.py' t 'gh#1 x' 'javascript:x|<!channel>' ambiguity 'gh#1' m | python3 -c 'import json,sys; t=json.load(sys.stdin)[\"text\"]; assert \"javascript\" not in t and \"<!channel>\" not in t, t'"
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
pr_field() { python3 -c "import json,sys; print(json.dumps(json.load(open('$FAKE_GH_DIR/issues.json'))['pr'].get(sys.argv[1])))" "$1"; }
check "request-review: codex gets one mention comment with the request marker" sh -c "python3 -c \"import json,sys; c=[b for b in json.loads(sys.argv[1]) if 'flow:review-request codex' in b]; assert len(c)==1 and c[0].startswith('@codex please review the diff.'), c\" '$(pr_field comments)'"
check "request-review: copilot is asked through the reviewers API" [ "$(pr_field reviewers)" = '["@copilot"]' ]
check "request-review: a reviewer not in the list is not asked" sh -c "! printf '%s' '$(pr_field comments)' | grep -q '@claude'"
check "request-review: the ask carries no chase marker" sh -c "! printf '%s' '$(pr_field comments)' | grep -q '<!-- flow:chase'"
cp "$work/config.reviews" .flow/config.yaml; printf 'reviews:\n  reviewers: [bad name]\n' >> .flow/config.yaml
check "reviewers: a name with a space is refused by name" sh -c "'$P/scripts/comments.sh' reviewers 2>&1 >/dev/null | grep -q \"'bad name' is not a reviewer name\""
cp "$work/config.reviews" .flow/config.yaml; printf 'reviews:\n  reviewers: [codex]\n  chase_after: 30m\n  max_chases: 1\n' >> .flow/config.yaml
seed() { # seed <request age s> <codex status> <+1 count> [chase|reply <body>|lookalike]: one request by the owner and the Codex summary
  python3 - "$FAKE_GH_DIR/issues.json" "$@" <<'PY2'
import json, sys, time
p, age, status, plus, extra = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4]), sys.argv[5:]
iso = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
asked = time.time() - age
owner, codex = {"login": "owner", "type": "User"}, {"login": "chatgpt-codex-connector[bot]", "type": "Bot"}
d = json.load(open(p)); pr = d["pr"]; pr["headRefOid"] = "abc1234def5678"; pr["comments"] = []; pr["reviews"] = []
state = '{"code_review":{"commit_sha":"abc1234def5678","status":"%s"}}' % status
pr["rest_comments"] = [{"id": 7, "user": owner, "body": "@codex please review", "created_at": iso(asked), "updated_at": iso(asked), "reactions": {"+1": plus}},
                       {"id": 8, "user": codex, "created_at": iso(asked - 3600), "updated_at": iso(asked + 5),
                        "body": "<!-- codex-pull-request-review-summary -->\n<!-- codex-review-state:v1 %s -->" % state, "reactions": {}}]
later = lambda user, body: {"id": 9, "user": user, "body": body, "created_at": iso(asked + 1), "updated_at": iso(asked + 1), "reactions": {}}
if extra[:1] == ["chase"]:
    pr["rest_comments"].append(later(owner, "@codex review\n\n<!-- flow:chase codex -->"))
elif extra[:1] == ["reply"]:
    pr["rest_comments"].append(later(codex, extra[1]))
elif extra[:1] == ["lookalike"]:
    pr["rest_comments"].append(later({"login": "xcodex", "type": "User"}, "Looks good to me."))
json.dump(d, open(p, "w"))
PY2
}
posted() { python3 -c "import json; print(len(json.load(open('$FAKE_GH_DIR/issues.json'))['pr']['comments']))"; }
answered() { "$P/scripts/comments.sh" reviews 91 | python3 -c "import json,sys; print(json.loads(sys.stdin.readline())['answered'])"; }
seed 7200 running 0
check "reviews: a Codex summary still running is no answer" [ "$(answered)" = False ]
check "reviews: the wait counts from the request" sh -c "'$P/scripts/comments.sh' reviews 91 | grep -q '\"waiting\": 72[0-9][0-9], \"chases\": 0'"
seed 7200 running 0 reply "You have reached your Codex usage limit. Try again later."
check "reviews: a usage-limit reply is no answer" [ "$(answered)" = False ]
seed 7200 running 0 reply "No issues found."
check "reviews: a plain reply from the reviewer answers" [ "$(answered)" = True ]
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

echo "jobs (fake hosts)"
export HOST_LOG="$work/host.log"; realrepo="$(cd "$repo" && pwd -P)"
for h in claude codex; do printf '#!/bin/sh\nprintf "%%s\\t%%s\\t%%s\\n" "$0" "$PWD" "$*" >> "$HOST_LOG"\n' > "$work/bin/$h"; chmod +x "$work/bin/$h"; done
"$P/adapters/github/write-state.sh" 'gh#21' step=pr && "$P/adapters/github/link-pr.sh" 'gh#21' https://gh/pull/90
"$P/jobs/comments.sh" claude >/dev/null
check "comments job: runs the skill per open PR from the main worktree" sh -c "grep -q 'claude	$realrepo	-p /flow:comments gh#21' '$HOST_LOG' && grep -q 'addressing gh#21' .flow/log/comments.log"
check "comments job: one PR, one run" [ "$(grep -c comments "$HOST_LOG")" = "1" ]
check "comments job: a mergeable PR gets no conflict note" sh -c "! grep -q 'Conflicts step' '$HOST_LOG'"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a PR with nothing new since the last pass is skipped, quiet" sh -c "[ ! -s '$HOST_LOG' ] && grep -q 'gh#21: nothing new since the last pass, skipped' .flow/log/comments.log && tail -1 .flow/log/comments.log | grep -q 'quiet: nothing new on 1 PR(s)'"
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr']['updatedAt']='2026-10-24T16:06:00Z'; json.dump(d, open(p,'w'))"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a new comment on the PR starts a pass" grep -q 'comments gh#21' "$HOST_LOG"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude 'gh#21' >/dev/null
check "comments job: a named PR runs even with nothing new" grep -q 'comments gh#21' "$HOST_LOG"
printf '#!/bin/sh\nexit 1\n' > "$work/bin/claude"
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr']['updatedAt']='2026-10-24T16:30:00Z'; json.dump(d, open(p,'w'))"
"$P/jobs/comments.sh" claude >/dev/null
printf '#!/bin/sh\nprintf "%%s\\t%%s\\t%%s\\n" "$0" "$PWD" "$*" >> "$HOST_LOG"\n' > "$work/bin/claude"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a pass the host failed is tried again" grep -q 'comments gh#21' "$HOST_LOG"
check "comments job: a failed pass is recorded as failed, not done" sh -c "grep -q 'gh#21: pass failed, host exit 1; the next run tries it again' .flow/log/comments.log && grep -q '\"exit\":1,\"result\":\"failed: gh#21 cut short or failed' .flow/log/runs.jsonl"
okhost='#!/bin/sh\nprintf "%%s\\t%%s\\t%%s\\n" "$0" "$PWD" "$*" >> "$HOST_LOG"\n'
bump() { python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr']['updatedAt']='$1'; json.dump(d, open(p,'w'))"; }
# The host stopping the addresser at its background-task ceiling exits 0, and is still a failed pass.
printf "$okhost"'echo "Background tasks still running 10m after the last turn (subagent \\"Address review thread\\"); stopping them. Set CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 to wait indefinitely."\necho "The addresser is working on the one open thread."\n' > "$work/bin/claude"
bump 2026-10-24T16:40:00Z
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null; code=$?
check "comments job: a pass the host cut short at its background ceiling is failed, exit 1" sh -c "[ $code -eq 1 ] && grep -q 'gh#21: pass failed, the host stopped the addresser before it finished' .flow/log/comments.log && tail -1 .flow/log/comments.log | grep -q 'failed: gh#21'"
resume_md="$("$P/scripts/steward.sh" reports 'gh#21')/comments-resume.md"
check "comments job: a cut-short pass leaves the next pass a resume note" sh -c "grep -q 'The previous comments pass on PR #90 was cut short at .*Read git status and git diff, continue from there' '$resume_md'"
check "comments job: the host's output reaches the log as the pass runs" grep -q 'The addresser is working on the one open thread.' .flow/log/comments.log
check "comments job: the output file goes with the run" sh -c "! ls .flow/log/comments.out.* >/dev/null 2>&1"
printf "$okhost" > "$work/bin/claude"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a cut-short pass is tried again with nothing new, told to read the note" sh -c "grep -q 'comments gh#21' '$HOST_LOG' && grep -q 'An earlier pass was cut short: read .*comments-resume.md first' '$HOST_LOG'"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: the retry that finished is the last pass, so the next run is quiet" [ ! -s "$HOST_LOG" ]
check "comments job: the pass that completed removes the resume note" [ ! -f "$resume_md" ]
printf "$okhost"'echo "Done. The log quoted: Background tasks still running 10m after the last turn; stopping them."\n' > "$work/bin/claude"
bump 2026-10-24T16:45:00Z
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null; code=$?
check "comments job: a good pass whose text quotes the ceiling line is not failed" sh -c "[ $code -eq 0 ] && tail -1 .flow/log/comments.log | grep -q 'done: 1 PR(s)'"
# Failures in a row with nothing changing: three tries, then the PR waits and the owner is told once.
printf '#!/bin/sh\nexit 1\n' > "$work/bin/claude"; bump 2026-10-24T16:50:00Z
for n in 1 2 3; do "$P/jobs/comments.sh" claude >/dev/null; done
printf "$okhost" > "$work/bin/claude"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: after three failed passes in a row the job stops trying the PR" sh -c "[ ! -s '$HOST_LOG' ] && grep -q 'gh#21: 3 passes in a row failed, skipped until a pass run by hand completes' .flow/log/comments.log"
check "comments job: the owner is told once about the failing PR" [ "$(grep -c 'comments	gh#21: the comments pass failed 3 times in a row' .flow/events.log)" = 1 ]
bump 2026-10-24T16:55:00Z; : > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: activity a cut-short pass may have made does not restart the retries" [ ! -s "$HOST_LOG" ]
"$P/jobs/comments.sh" claude 'gh#21' >/dev/null; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a pass run by hand that completes lets the job try the PR again" sh -c "[ \"\$(grep -c 'comments gh#21' '$HOST_LOG')\" = 1 ] && tail -1 .flow/log/comments.log | grep -q 'quiet: nothing new'"
# An unresolved thread whose last word is not the flow's reply waits on a pass.
python3 - "$FAKE_GH_DIR/issues.json" <<'PY3'
import json, sys
d = json.load(open(sys.argv[1]))
d["threads"] = [{"id": "T_9", "isResolved": False, "isOutdated": False, "path": "src/R.cs", "line": 7,
                 "comments": {"nodes": [{"databaseId": 901, "body": "This drops the slide.", "author": {"login": "chatgpt-codex-connector"}, "createdAt": "t"}]}}]
json.dump(d, open(sys.argv[1], "w"))
PY3
check "activity: counts the unresolved threads, their comments and the last comment of the ones awaiting us" sh -c "'$P/scripts/comments.sh' activity 90 | python3 -c 'import json,sys; a=json.load(sys.stdin); assert (a[\"unresolved\"],a[\"review_comments\"],a[\"awaiting\"])==(1,1,[901]), a'"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a new review thread starts a pass" grep -q 'comments gh#21' "$HOST_LOG"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a thread still awaiting a reply gets one more pass" sh -c "grep -q 'comments gh#21' '$HOST_LOG' && grep -q 'gh#21: open thread(s) 901 still wait on a reply, one more pass' .flow/log/comments.log"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: then the same awaiting threads are skipped, and the owner told once" sh -c "[ ! -s '$HOST_LOG' ] && [ \"\$(grep -c 'comments	gh#21: review thread(s) on .* still wait on a reply after two passes' .flow/events.log)\" = 1 ]"
check "activity: a reply from before 1.19.0 (no marker) by the flow's login is ours" sh -c "python3 - '$FAKE_GH_DIR/issues.json' <<'PY5'
import json, sys
d = json.load(open(sys.argv[1]))
d['threads'].append({'id': 'T_10', 'isResolved': False, 'isOutdated': False, 'path': 'src/S.cs', 'line': 1,
                     'comments': {'nodes': [{'databaseId': 1001, 'body': 'Rename this.', 'author': {'login': 'chatgpt-codex-connector'}, 'createdAt': 't'},
                                            {'databaseId': 1002, 'body': 'Renamed in abc.', 'author': {'login': 'owner'}, 'createdAt': 't'}]}})
json.dump(d, open(sys.argv[1], 'w'))
PY5
'$P/scripts/comments.sh' activity 90 | grep -q '\"awaiting\": \[901\]'"
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['threads']=d['threads'][:1]; json.dump(d, open(p,'w'))"
"$P/scripts/comments.sh" reply 90 901 "Kept the slide, as the owner asked."
check "reply: the flow's reply carries its marker" sh -c "python3 -c \"import json; d=json.load(open('$FAKE_GH_DIR/issues.json')); assert '<!-- flow:reply -->' in d['threads'][0]['comments']['nodes'][-1]['body']\""
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: our reply on the thread counts as new once" grep -q 'comments gh#21' "$HOST_LOG"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a thread whose last word is the flow's reply waits on the reviewer, skipped" sh -c "[ ! -s '$HOST_LOG' ] && tail -1 .flow/log/comments.log | grep -q 'quiet: nothing new on 1 PR(s)'"
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['threads'][0]['comments']['nodes'].append({'databaseId': 902, 'body': 'Keep it: I want the slide.', 'author': {'login': 'owner'}, 'createdAt': 't'}); json.dump(d, open(p,'w'))"
check "activity: the owner's reply under the flow's login, after a marked reply, awaits a reply" sh -c "'$P/scripts/comments.sh' activity 90 | grep -q '\"awaiting\": \[902\]'"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: the owner's answer on the thread starts a pass" grep -q 'comments gh#21' "$HOST_LOG"
# An item at a gate (not merge) is the owner's: no pass, even with a thread awaiting.
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['threads'][0]['comments']['nodes'].append({'databaseId': 903, 'body': 'And this?', 'author': {'login': 'chatgpt-codex-connector'}, 'createdAt': 't'}); json.dump(d, open(p,'w'))"
"$P/adapters/github/write-state.sh" 'gh#21' gate=ambiguity
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: an item waiting at a gate is skipped, threads or not" sh -c "[ ! -s '$HOST_LOG' ] && grep -q 'gh#21: waits at the ambiguity gate, skipped' .flow/log/comments.log"
"$P/jobs/comments.sh" claude 'gh#21' >/dev/null
check "comments job: a named PR runs at a gate" grep -q 'comments gh#21' "$HOST_LOG"
"$P/adapters/github/write-state.sh" 'gh#21' gate=merge
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: the merge gate does not stop a pass" grep -q 'comments gh#21' "$HOST_LOG"
"$P/adapters/github/write-state.sh" 'gh#21' gate=none
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['threads']=[]; json.dump(d, open(p,'w'))"
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr']['mergeable']='CONFLICTING'; json.dump(d, open(p,'w'))"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a PR that conflicts with its base is named in the brief" grep -q 'gh#21. The PR conflicts with its base main: run the Conflicts step first.' "$HOST_LOG"
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr']['baseRefName']='main;touch x'; json.dump(d, open(p,'w'))"
: > "$HOST_LOG"; "$P/jobs/comments.sh" claude >/dev/null
check "comments job: a base name with shell characters never reaches the brief" sh -c "! grep -q 'touch x' '$HOST_LOG' && grep -q 'conflicts with a base named oddly' .flow/log/comments.log"
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr']['baseRefName']='main'; d['pr']['mergeable']='MERGEABLE'; json.dump(d, open(p,'w'))"
: > "$HOST_LOG"
"$P/jobs/comments.sh" codex >/dev/null
check "comments job on codex: exec in the main worktree" sh -c "grep -q 'codex	.*	exec -C $realrepo -s workspace-write' '$HOST_LOG'"
check "a job starts its skill as typed: /plugin:skill on Claude, \$skill on Codex" sh -c "grep -q 'codex	.*workspace-write.* \\\$comments gh#21' '$HOST_LOG' && [ \"\$(FLOW_PLUGIN='$P' sh -c '. \"$P/lib/host.sh\"; host_skill_prompt claude flow implement gh#7')\" = '/flow:implement gh#7' ]"
check "the unattended loop starts a skill step as typed" grep -q 'host_skill_prompt "$host" flow "$skill"' "$P/templates/run-unattended.sh"
printf 'adapters:\n  default: github\nbase: main\ngithub:\n  repo: acme/widgets\npool:\n  - ../wt-1\n  - ../wt-2\nnotify:\n  desktop: false\njobs:\n  model: haiku\n  effort: low\n' > .flow/config.yaml
"$P/jobs/comments.sh" claude 'gh#21' >/dev/null
check "jobs.model and jobs.effort reach the host" sh -c "grep -q 'gh#21.*--model haiku --effort low' '$HOST_LOG'"
check "the old jobs.model and jobs.effort are a fallback, with one deprecation warning naming the new keys" sh -c "[ \"\$(grep -c 'jobs.model and jobs.effort are deprecated: set jobs.claude.model and jobs.claude.effort' .flow/log/comments.log)\" = 1 ]"
jobscfg() { printf 'adapters:\n  default: github\nbase: main\ngithub:\n  repo: acme/widgets\npool:\n  - ../wt-1\n  - ../wt-2\nnotify:\n  desktop: false\njobs:\n%b' "$1" > .flow/config.yaml; }
deprecated() { grep -c 'jobs.model and jobs.effort are deprecated' .flow/log/comments.log; }
jobscfg '  model: opus\n  effort: high\n'; : > "$HOST_LOG"; "$P/jobs/comments.sh" codex 'gh#21' >/dev/null
check "the fallback maps the old model for codex: opus is gpt-6-sol" sh -c "grep -q 'exec .*-m gpt-6-sol -c model_reasoning_effort=\"high\"' '$HOST_LOG'"
jobscfg '  model: haiku\n  effort: low\n  claude:\n    model: claude-opus-x\n    effort: xhigh\n'; : > "$HOST_LOG"; before="$(deprecated)"; "$P/jobs/comments.sh" claude 'gh#21' >/dev/null
check "jobs.claude.model and jobs.claude.effort reach claude as --model and --effort, as is" sh -c "grep -q 'gh#21.*--model claude-opus-x --effort xhigh' '$HOST_LOG'"
check "with jobs.claude set, the old keys are not read and no warning is logged" [ "$(deprecated)" = "$before" ]
jobscfg '  codex:\n    model: opus\n    effort: xhigh\n'; : > "$HOST_LOG"; "$P/jobs/comments.sh" codex 'gh#21' >/dev/null
check "jobs.codex.model and jobs.codex.effort reach codex exec as -m and model_reasoning_effort, unmapped" sh -c "grep -q 'exec .*-m opus -c model_reasoning_effort=\"xhigh\"' '$HOST_LOG'"
jobscfg '  model: haiku\n  effort: low\n  claude:\n    model: ""\n    effort: ""\n'; : > "$HOST_LOG"; "$P/jobs/comments.sh" claude 'gh#21' >/dev/null
check "an empty jobs.claude pair is the host default: no --model, no --effort, no fallback" sh -c "grep -q 'gh#21' '$HOST_LOG' && ! grep -q -- '--model\|--effort' '$HOST_LOG'"
jobscfg '  codex:\n    effort: max\n'; : > "$HOST_LOG"
"$P/jobs/comments.sh" codex 'gh#21' >/dev/null 2>"$work/job.err"; code=$?
check "an effort codex does not take fails the job early, exit 2, naming the key and its line" sh -c "[ $code = 2 ] && grep -q 'flow: .flow/config.yaml:13: jobs.codex.effort is max; codex takes low, medium, high or xhigh' '$work/job.err' && [ ! -s '$HOST_LOG' ]"
check "a refused effort is a failed run in runs.jsonl, so status shows it" sh -c "tail -1 .flow/log/runs.jsonl | grep -q '\"job\":\"comments\".*\"exit\":2,\"result\":\"error: .flow/config.yaml:13: jobs.codex.effort is max'"
check "a refused effort leaves one line in the job log" [ "$(grep -c 'error: .flow/config.yaml:13: jobs.codex.effort is max' .flow/log/comments.log)" = 1 ]
jobscfg '  claude:\n    effort: max\n'; : > "$HOST_LOG"; "$P/jobs/comments.sh" claude 'gh#21' >/dev/null 2>&1
check "max is a claude effort" grep -q 'gh#21.*--effort max' "$HOST_LOG"
jobscfg '  host: vim\n'; : > "$HOST_LOG"
"$P/jobs/comments.sh" claude 'gh#21' >/dev/null 2>"$work/job.err"; code=$?
check "a jobs.host other than claude or codex fails the job early, exit 2" sh -c "[ $code = 2 ] && grep -q 'jobs.host is vim; it must be claude or codex' '$work/job.err' && [ ! -s '$HOST_LOG' ]"
check "jobs.sh run refuses a bad jobs.host, exit 2" sh -c "'$P/scripts/jobs.sh' run comments 2>&1; [ \$? = 2 ]"
printf 'adapters:\n  default: github\nbase: main\ngithub:\n  repo: acme/widgets\npool:\n  - ../wt-1\n  - ../wt-2\nnotify:\n  desktop: false\njobs:\n  model: haiku\n  effort: low\n' > .flow/config.yaml
check "the unattended loop keeps mapping the roster's names for codex" sh -c "FLOW_PLUGIN='$P' sh -c '. \"$P/lib/flow.sh\"; . \"$P/lib/host.sh\"; host_run codex . hi opus high' && grep -q 'exec .*-m gpt-6-sol' '$HOST_LOG'"
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr']['state']='MERGED'; json.dump(d, open(p,'w'))"
: > "$HOST_LOG"
"$P/jobs/comments.sh" claude >/dev/null
check "comments job: merged PR skipped, quiet" sh -c "[ ! -s '$HOST_LOG' ] && grep -q 'quiet: no open PR' .flow/log/comments.log"
# A stand-in run: its command line names jobs/comments.sh, as a real run's does, and it has a child.
mkdir -p "$work/fake/jobs" && printf '#!/bin/sh\nsleep 60 &\nwait\n' > "$work/fake/jobs/comments.sh" && chmod +x "$work/fake/jobs/comments.sh"
fakejob="$(sh -c '"$1" >/dev/null 2>&1 & echo $!' _ "$work/fake/jobs/comments.sh")"
mkdir -p .flow/log/comments.lock && echo "$fakejob" > .flow/log/comments.lock/pid
check "job lock: live pid skips"  sh -c "'$P/jobs/comments.sh' claude | grep -q 'skipped: run $fakejob still going'"
pkill -P "$fakejob" 2>/dev/null; kill "$fakejob" 2>/dev/null
echo 999999 > .flow/log/comments.lock/pid
check "job lock: stale pid runs" sh -c "'$P/jobs/comments.sh' claude | grep -q 'quiet: no open PR' && [ ! -d .flow/log/comments.lock ]"
sleep 60 & other=$!
mkdir -p .flow/log/comments.lock && echo "$other" > .flow/log/comments.lock/pid
check "job lock: a pid a restart gave to another process is stale, and that process is left alone" sh -c "'$P/jobs/comments.sh' claude | grep -q 'quiet: no open PR' && [ ! -d .flow/log/comments.lock ] && kill -0 $other"
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
check "job: unknown host refused" sh -c "! '$P/jobs/comments.sh' vim 2>/dev/null"
home2="$work/home2"; mkdir -p "$home2"
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\nnotify:\n  desktop: false\njobs:\n  claude:\n    effort: bogus\n' > "$home2/config.yaml"
check "next job: a bad jobs.claude.effort does not stop it, it never reads the pair" sh -c "FLOW_HOME='$home2' '$P/jobs/next.sh' claude | grep -q 'quiet: nothing ready'"
check "health job: a bad jobs.claude.effort does not stop it either" sh -c "FLOW_HOME='$home2' '$P/jobs/health.sh' claude --dry-run >/dev/null 2>&1; [ \$? != 2 ] && tail -1 '$home2/log/runs.jsonl' | grep -q '\"job\":\"health\"' && ! tail -1 '$home2/log/runs.jsonl' | grep -q '\"exit\":2'"
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\nnotify:\n  desktop: false\njobs:\n  host: vim\n' > "$home2/config.yaml"
FLOW_HOME="$home2" "$P/jobs/next.sh" claude >/dev/null 2>"$work/job.err"; code=$?
check "next job: a bad jobs.host stops every job, exit 2" sh -c "[ $code = 2 ] && grep -q 'jobs.host is vim' '$work/job.err'"
rm -rf "$home2/log"
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\nnotify:\n  desktop: false\n' > "$home2/config.yaml"
check "next job: nothing ready is quiet" sh -c "FLOW_HOME='$home2' '$P/jobs/next.sh' claude | grep -q 'quiet: nothing ready'"
check "next job: no idle notification unless notify.idle is on" sh -c "! grep -q '	idle	' '$home2/events.log' 2>/dev/null"
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\nnotify:\n  desktop: false\n  idle: true\n' > "$home2/config.yaml"
FLOW_HOME="$home2" "$P/jobs/next.sh" claude >/dev/null; FLOW_HOME="$home2" "$P/jobs/next.sh" claude >/dev/null
check "next job: notify.idle says it once, not on every run" [ "$(grep -c '	idle	' "$home2/events.log")" = 1 ]
check "the idle notice is an event, not a gate" sh -c "[ -z \"\$(ls '$home2/gates' 2>/dev/null)\" ]"
check "retro job: no lessons is quiet" sh -c "FLOW_HOME='$home2' '$P/jobs/retro.sh' claude | grep -q 'quiet: 0 new'"
FLOW_HOME="$home2" "$P/scripts/lesson.sh" review-blocker 'local:task/9' "Magic number" --rule N-06 >/dev/null
FLOW_HOME="$home2" "$P/scripts/lesson.sh" escalation 'local:task/9' "verify failed 3 times" >/dev/null
: > "$HOST_LOG"
check "retro job: new lessons run the skill" sh -c "FLOW_HOME='$home2' '$P/jobs/retro.sh' claude | grep -q 'running over 2 new' && grep -q '/meta:retro Unattended.*Read the 2 lessons.*2 lines, 0 read before' '$HOST_LOG'"
printf '%s\t2\t1\t1\n' "$(date -u +%FT%TZ)" > "$home2/retros.log"
check "retro job: retros.log marks the lessons read" sh -c "FLOW_HOME='$home2' '$P/jobs/retro.sh' claude --min-lessons 1 | grep -q 'quiet: 0 new'"
lessons_clone() { # lessons_clone <dir> <more config>: <dir>/origin.git and its clone <dir>/app on main, the flow home tracked
  mkdir -p "$1" && git init -q --bare "$1/origin.git" && git clone -q "$1/origin.git" "$1/app" 2>/dev/null && (cd "$1/app" &&
    git config user.email t@t && git config user.name t && mkdir -p .flow && printf '.flow/log/\n.flow/tmp/\n' > .gitignore &&
    printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\nnotify:\n  desktop: false\n%b' "$2" > .flow/config.yaml &&
    printf '%s\t0\t0\t0\n' "$(date -u +%FT%TZ)" > .flow/retros.log && git add -A && git commit -qm init &&
    git push -q origin HEAD:main 2>/dev/null && git branch -q -M main && git branch -q -u origin/main &&
    "$P/scripts/lesson.sh" review-blocker 'local:task/9' "Magic number" --rule N-06 >/dev/null)
}
lessons_clone "$work/lessons" ""
(cd "$work/lessons/app" && "$P/jobs/retro.sh" claude) > "$work/lessons.out" 2>&1
check "retro job: the lessons are committed alone on the base branch and pushed" sh -c "git -C '$work/lessons/origin.git' log -1 --format=%s main | grep -q '^chore(flow): record the lessons the retro read' && [ \"\$(git -C '$work/lessons/origin.git' show --name-only --format= main | tr '\n' ' ')\" = '.flow/lessons.jsonl ' ] && grep -q 'lessons log pushed' '$work/lessons.out' && [ -z \"\$(git -C '$work/lessons/app' status --porcelain -- .flow/lessons.jsonl)\" ]"
(cd "$work/lessons/app" && "$P/scripts/lesson.sh" escalation 'local:task/9' "again" >/dev/null && "$P/jobs/retro.sh" claude --min-lessons 5) > "$work/lessons.out" 2>&1
check "retro job: a quiet run still commits and pushes the lessons recorded since" sh -c "grep -q 'quiet: 2 new' '$work/lessons.out' && git -C '$work/lessons/origin.git' show main:.flow/lessons.jsonl | grep -q again"
lessons_clone "$work/lessons-off" ""
(cd "$work/lessons-off/app" && git checkout -q -b other && "$P/jobs/retro.sh" claude) > "$work/lessons.out" 2>&1
check "retro job: off the base branch the lessons are left uncommitted" sh -c "grep -q 'not on main: the lessons log is left uncommitted' '$work/lessons.out' && git -C '$work/lessons-off/app' status --porcelain | grep -q 'lessons.jsonl' && [ \"\$(git -C '$work/lessons-off/app' rev-list --count HEAD)\" = 1 ]"
lessons_clone "$work/lessons-no" "retro:\n  commit: false\n"
(cd "$work/lessons-no/app" && "$P/jobs/retro.sh" claude) > "$work/lessons.out" 2>&1
check "retro job: retro.commit false leaves the lessons uncommitted" sh -c "git -C '$work/lessons-no/app' status --porcelain | grep -q 'lessons.jsonl' && [ \"\$(git -C '$work/lessons-no/origin.git' rev-list --count main)\" = 1 ]"
lessons_clone "$work/lessons-ign" ""
(cd "$work/lessons-ign/app" && git rm -q --cached .flow/retros.log && printf '.flow/retros.log\n' >> .gitignore && git commit -qam ignore && git push -q 2>/dev/null; "$P/jobs/retro.sh" claude) > "$work/lessons.out" 2>&1
check "retro job: an ignored retros.log is left out and the lessons are still committed" sh -c "grep -q 'git ignores .flow/retros.log: left out of the lessons commit' '$work/lessons.out' && [ \"\$(git -C '$work/lessons-ign/origin.git' show --name-only --format= main)\" = .flow/lessons.jsonl ]"

echo "flow jobs: the run ledger, pause and the schedule (fake launchctl)"
J="$P/scripts/jobs.sh"
check "a run is a line in runs.jsonl: job, start, length, exit, last words" sh -c "grep '\"job\":\"comments\"' .flow/log/runs.jsonl | grep -q '\"exit\":0,\"result\":\"quiet: no open PR\"'"
check "a run skipped by a live lock is a line too" grep -q '"result":"skipped: run' .flow/log/runs.jsonl
check "next workers record their own runs" grep -q '"job":"next"' "$home2/log/runs.jsonl"
FLOW_HOME="$home2" "$P/jobs/intake.sh" claude >/dev/null 2>&1
check "a job that dies after it starts records the error and its exit" sh -c "tail -1 '$home2/log/runs.jsonl' | grep -q '\"exit\":1,\"result\":\"error: no notes file'"
: > "$HOST_LOG"
FLOW_HOME="$home2" "$J" pause retro >/dev/null
FLOW_HOME="$home2" "$P/scripts/lesson.sh" escalation 'local:task/9' "again" >/dev/null
check "a paused job exits at once and spends nothing" sh -c "FLOW_HOME='$home2' '$P/jobs/retro.sh' claude | grep -q '^.*paused:' && [ ! -s '$HOST_LOG' ] && tail -1 '$home2/log/runs.jsonl' | grep -q '\"result\":\"paused'"
FLOW_HOME="$home2" "$J" pause next >/dev/null
check "a paused next skips the tracker sync and every worker" sh -c "FLOW_HOME='$home2' '$P/jobs/next.sh' claude --workers 2 | grep -q 'paused' && [ ! -f '$home2/log/next-1.log' ]"
FLOW_HOME="$home2" "$J" resume all >/dev/null
check "resume all clears every pause" sh -c "! ls '$home2'/log/*.paused 2>/dev/null"
check "jobs: an unknown job is refused" sh -c "! '$J' history vim 2>/dev/null"
mkdir -p "$work/agents"
cat > "$work/bin/launchctl" <<'SH'
#!/bin/sh
echo "launchctl $*" >> "$LAUNCH_LOG"
case "$1" in
  print) [ -f "$LAUNCH_DIR/${2##*/}.loaded" ] || exit 113; printf '\tstate = not running\n\truns = 3\n\tlast exit code = 0\n' ;;
  bootstrap) touch "$LAUNCH_DIR/$(basename "$3" .plist).loaded" ;;
  bootout) rm -f "$LAUNCH_DIR/${2##*/}.loaded" ;;
esac
SH
chmod +x "$work/bin/launchctl"
export LAUNCH_LOG="$work/launchctl.log" LAUNCH_DIR="$work/agents" FLOW_LAUNCH_AGENTS="$work/agents" FLOW_SCHEDULER=launchd
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\nnotify:\n  desktop: false\njobs:\n  schedule:\n    next: every 30m --workers 2 --max-steps 15\n    comments: every 2h\n    intake: daily 02:00\n    retro: weekly sun 03:30\n' > "$home2/config.yaml"
lbl="com.$(basename "$repo" | tr 'A-Z' 'a-z').flow"
FLOW_HOME="$home2" "$J" install > "$work/install.out"
check "install writes a launchd agent per scheduled job and loads it" sh -c "[ \$(ls '$work/agents'/*.plist | wc -l) = 4 ] && [ \$(grep -c bootstrap '$LAUNCH_LOG') = 4 ]"
check "install: every 30m is a 1800 s interval, with the job's args" sh -c "grep -q '<integer>1800</integer>' '$work/agents/$lbl.next.plist' && grep -q 'next.sh claude --workers 2 --max-steps 15' '$work/agents/$lbl.next.plist' && grep -q '<integer>7200</integer>' '$work/agents/$lbl.comments.plist'"
check "install: daily and weekly are calendar times, Sunday is 0" sh -c "grep -q '<key>Hour</key><integer>2</integer><key>Minute</key><integer>0</integer>' '$work/agents/$lbl.intake.plist' && grep -q '<key>Minute</key><integer>30</integer><key>Weekday</key><integer>0</integer>' '$work/agents/$lbl.retro.plist'"
FLOW_HOME="$home2" "$J" install next > /dev/null
check "install again unloads the old agent first" sh -c "grep -q 'bootout gui/.*/$lbl.next' '$LAUNCH_LOG'"
FLOW_HOME="$home2" "$J" status --json > "$work/status.json"
check "status: schedule, loaded, launchd's run count, the last run and what it said" sh -c "python3 -c 'import json,sys; r={x[\"job\"]:x for x in json.load(open(sys.argv[1]))}; n=r[\"next\"]; i=r[\"intake\"]; assert n[\"schedule\"]==\"every 30m\" and n[\"args\"]==\"--workers 2 --max-steps 15\" and n[\"loaded\"] and n[\"launchd\"][\"runs\"]==3, n; assert i[\"last\"][\"outcome\"]==\"failed\" and i[\"last\"][\"result\"].startswith(\"error\"), i; assert r[\"retro\"][\"week\"][\"paused\"]==1' '$work/status.json'"
check "status: the next run of a calendar job is a time, an interval job is due after a long gap" sh -c "python3 -c 'import json,sys,re; r={x[\"job\"]:x for x in json.load(open(sys.argv[1]))}; assert re.match(r\"[A-Z][a-z]{2} \d\d 02:00\", r[\"intake\"][\"next\"]), r[\"intake\"][\"next\"]' '$work/status.json'"
check "status prints a table" sh -c "FLOW_HOME='$home2' '$J' status | grep -q '^| intake | daily 02:00 | scheduled |'"
check "history lists the runs, newest first" sh -c "FLOW_HOME='$home2' '$J' history intake 5 | sed -n 3p | grep -q '| failed | error: no notes file'"
printf 'jobs:\n  schedule:\n    next: hourly\n' > "$home2/config.yaml"
check "install refuses a schedule it cannot read" sh -c "! FLOW_HOME='$home2' '$J' install next 2>&1 | grep -q 'as $lbl'"
printf 'jobs:\n  schedule:\n    next: every 30m\n    intake: weekly sun 03:30\n' > "$home2/config.yaml"
check "install elsewhere prints the crontab lines" sh -c "FLOW_SCHEDULER=cron FLOW_HOME='$home2' '$J' install | grep -q '^\*/30 \* \* \* \* cd .*next.sh claude' && FLOW_SCHEDULER=cron FLOW_HOME='$home2' '$J' install intake | grep -q '^30 3 \* \* 0 '"
home3="$work/flow home"; mkdir -p "$home3" && cp "$home2/config.yaml" "$home3/config.yaml"
check "the crontab line quotes a flow home with a space" sh -c "FLOW_SCHEDULER=cron FLOW_HOME='$home3' '$J' install next | grep -qF \">> '$home3/log/launchd-next.log' 2>&1\""
printf 'jobs:\n  schedule:\n    next: every 90m\n    comments: every 45m\n    intake: every 15m\n    retro: every 2h\n' > "$home2/config.yaml"
for j in next comments; do
  check "cron refuses $(yaml_get "$home2/config.yaml" jobs.schedule.$j), naming the intervals it can run" sh -c "! FLOW_SCHEDULER=cron FLOW_HOME='$home2' '$J' install $j >/dev/null 2>&1 && FLOW_SCHEDULER=cron FLOW_HOME='$home2' '$J' install $j 2>&1 | grep -q 'minutes that divide 60.*hours that divide 24'"
done
check "cron takes every 15m and every 2h" sh -c "FLOW_SCHEDULER=cron FLOW_HOME='$home2' '$J' install intake | grep -q '^\*/15 \* \* \* \* ' && FLOW_SCHEDULER=cron FLOW_HOME='$home2' '$J' install retro | grep -q '^0 \*/2 \* \* \* '"
printf 'jobs:\n  schedule:\n    next: every 30m ; touch %s/pwned\n' "$work" > "$home2/config.yaml"
check "install refuses an arg that is not a plain option or value and writes nothing" sh -c "! FLOW_HOME='$home2' '$J' install next >/dev/null 2>&1 && FLOW_HOME='$home2' '$J' install next 2>&1 | grep -q 'one option or value' && ! grep -q pwned '$work/agents/$lbl.next.plist'"
check "run refuses it too and runs nothing" sh -c "FLOW_HOME='$home2' '$J' run next >/dev/null 2>&1; c=\$?; sleep 1; [ \$c -ne 0 ] && [ ! -e '$work/pwned' ]"
printf 'jobs:\n  schedule:\n    next: every 30m\n    intake: daily 25:00\n    retro: weekly sun 07:61\n' > "$home2/config.yaml"
check "install refuses a time out of range" sh -c "FLOW_HOME='$home2' '$J' install intake 2>&1 | grep -q 'no time 25:00' && FLOW_HOME='$home2' '$J' install retro 2>&1 | grep -q 'no time 07:61' && ! FLOW_HOME='$home2' '$J' install retro >/dev/null 2>&1"
check "status shows a bad schedule's error in its row and the other jobs as usual" sh -c "FLOW_HOME='$home2' '$J' status > '$work/bad.out' && grep -q '^| intake | error: .*25:00' '$work/bad.out' && grep -q '^| next | every 30m |' '$work/bad.out' && FLOW_HOME='$home2' '$J' status --json | python3 -c 'import json,sys; r={x[\"job\"]:x for x in json.load(sys.stdin)}; assert \"07:61\" in r[\"retro\"][\"error\"] and \"error\" not in r[\"next\"]'"
printf 'jobs:\n  schedule:\n    next: every 30m\n    comments: every 2h\n' > "$home2/config.yaml"
printf 'the job said this\n' >> "$home2/log/next.log"; printf 'a worker said this\n' > "$home2/log/next-1.log"
check "logs prints the job's log and each worker's" sh -c "FLOW_HOME='$home2' '$J' logs next 5 > '$work/logs.out' && grep -q '^== next.log' '$work/logs.out' && grep -q 'the job said this' '$work/logs.out' && grep -q '^== next-1.log' '$work/logs.out' && grep -q 'a worker said this' '$work/logs.out'"
fakejob="$(sh -c '"$1" >/dev/null 2>&1 & echo $!' _ "$work/fake/jobs/comments.sh")"
sleep 1; fakechild="$(pgrep -P "$fakejob")"
mkdir -p "$home2/log/comments.lock" && echo "$fakejob" > "$home2/log/comments.lock/pid"
check "run refuses a job that is running" sh -c "FLOW_HOME='$home2' '$J' run comments | grep -q 'running already'"
check "status shows a running job" sh -c "FLOW_HOME='$home2' '$J' status --json | python3 -c 'import json,sys; r={x[\"job\"]:x for x in json.load(sys.stdin)}; assert r[\"comments\"][\"running\"][0][\"pid\"]==$fakejob'"
FLOW_HOME="$home2" "$J" stop comments >/dev/null
sleep 1
check "stop ends the running run and every process under it" sh -c "[ -n '$fakechild' ] && ! kill -0 $fakejob 2>/dev/null && ! kill -0 $fakechild 2>/dev/null"
sleep 60 & other=$!
echo "$other" > "$home2/log/comments.lock/pid"
check "a lock whose pid now runs something else is not a running job" sh -c "FLOW_HOME='$home2' '$J' status --json | python3 -c 'import json,sys; r={x[\"job\"]:x for x in json.load(sys.stdin)}; assert r[\"comments\"][\"running\"]==[]'"
check "stop leaves that process alone" sh -c "FLOW_HOME='$home2' '$J' stop comments | grep -q 'not running' && kill -0 $other"
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
rm -rf "$home2/log/comments.lock"
FLOW_HOME="$home2" "$J" uninstall >/dev/null
check "uninstall unloads and removes every agent" sh -c "[ -z \"\$(ls '$work/agents'/*.plist 2>/dev/null)\" ] && [ \$(grep -c bootout '$LAUNCH_LOG') -ge 5 ]"
unset FLOW_LAUNCH_AGENTS FLOW_SCHEDULER

echo "intake (fake hosts)"
cat > "$work/notes.md" <<'MD'
# Notes:

- First note, with a detail
	- sub line under it

## Bugs:

- Second note
- [x] already done
- filed long ago #promoted -> #3

### Code
- Third note
	```c#
	var x = 1;
	```
MD
python3 -I "$P/scripts/_intake.py" parse "$work/notes.md" "$work/none.jsonl" 10 > "$work/parsed.json"
check "intake parse: bullets with their sub-lines, checked and promoted ones skipped" sh -c "python3 -c 'import json; d=json.load(open(\"$work/parsed.json\")); n=d[\"notes\"]; assert [x[\"id\"] for x in n]==[\"n1\",\"n2\",\"n3\"] and \"sub line\" in n[0][\"text\"] and \"var x\" in n[2][\"text\"] and d[\"left\"]==0'"
check "intake parse: the section is the heading chain" sh -c "python3 -c 'import json; n=json.load(open(\"$work/parsed.json\"))[\"notes\"]; assert (n[0][\"section\"],n[2][\"section\"])==(\"Notes\",\"Notes > Bugs > Code\")'"
check "intake parse: the batch caps it and counts the rest" sh -c "python3 -I '$P/scripts/_intake.py' parse '$work/notes.md' '$work/none.jsonl' 1 | python3 -c 'import json,sys; d=json.load(sys.stdin); assert len(d[\"notes\"])==1 and d[\"left\"]==2'"
cat > "$work/bin/claude" <<'SH'
#!/bin/sh
printf '%s\t%s\t%s\n' "$0" "$PWD" "$*" >> "$HOST_LOG"
out="$(printf '%s' "$*" | sed -n 's/.* and write \([^ ]*results.json\).*/\1/p')"
[ -n "$out" ] && [ -z "${FAKE_NO_RESULTS:-}" ] && python3 -c "
import json, os, sys
n = json.load(open(os.path.join(os.path.dirname(sys.argv[1]), 'notes.json')))['notes'][0]
o = 'filed' if 'First' in n['text'] else 'duplicate' if 'Second' in n['text'] else 'kept'
json.dump([{'note': n['id'], 'outcome': o, 'issues': []}], open(sys.argv[1], 'w'))" "$out"
exit 0
SH
chmod +x "$work/bin/claude"
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\nnotify:\n  desktop: false\njobs:\n  permission_mode: auto\nintake:\n  notes: %s\n' "$work/notes.md" > "$home2/config.yaml"
cp "$work/notes.md" "$work/notes.orig"
check "intake job: no notes file is quiet" sh -c "FLOW_HOME='$home2' '$P/jobs/intake.sh' claude --notes '$work/missing.md' | grep -q 'quiet: no notes file'"
FAKE_NO_RESULTS=1 FLOW_HOME="$home2" "$P/jobs/intake.sh" claude >/dev/null 2>&1; code=$?
check "intake job: no results file fails and leaves the notes" sh -c "[ $code -eq 1 ] && cmp -s '$work/notes.md' '$work/notes.orig'"
: > "$HOST_LOG"
FLOW_HOME="$home2" "$P/jobs/intake.sh" claude > "$work/intake.out"
check "intake job: one session per note, with jobs.permission_mode" sh -c "[ \$(grep -c -- '-p /flow:intake on' '$HOST_LOG') = 3 ] && grep -q -- '--permission-mode auto' '$HOST_LOG'"
check "intake job: filed and duplicate notes leave the file, kept ones and headings stay" sh -c "! grep -q 'First note' '$work/notes.md' && ! grep -q 'sub line' '$work/notes.md' && ! grep -q 'Second note' '$work/notes.md' && grep -q 'Third note' '$work/notes.md' && grep -q '^## Bugs' '$work/notes.md' && grep -q 'already done' '$work/notes.md'"
check "intake job: removing a note leaves the blank lines elsewhere as they were" sh -c "python3 -c 'import sys; s=open(sys.argv[1]).read(); assert \"\\n\\n\\n\" not in s and s.startswith(\"# Notes:\\n\\n## Bugs:\\n\\n- [x]\")' '$work/notes.md'"
check "intake job: the ledger records the handled notes" [ "$(wc -l < "$home2/log/intake-ledger.jsonl" | tr -d ' ')" = 2 ]
check "intake job: says what it did" grep -q 'done: duplicate 1 filed 1 kept 1' "$work/intake.out"
cp "$work/notes.orig" "$work/kept.md"
: > "$HOST_LOG"
FLOW_HOME="$home2" "$P/jobs/intake.sh" claude --notes "$work/kept.md" --keep-notes >/dev/null
check "intake job: --keep-notes leaves the file and the ledger skips what it filed" sh -c "cmp -s '$work/kept.md' '$work/notes.orig' && [ \$(grep -c -- '-p /flow:intake on' '$HOST_LOG') = 1 ] && grep -q 'Third note' \$(grep -l Third '$home2'/tmp/intake-*/n1/notes.json | tail -1)"
cat > "$work/old.md" <<'MD'
## Bots

- [ ] Ball spins forever  #bug  ^spin
    - desc: after a goalpost edge
    - rel: ^refl
- [ ] Why does a free rod swing?  ^why
- [ ] Old net settings  #parked  ^net
- [ ] Vague thing  ^vague
- [ ] Spins again #dup (see ^spin) ^spin2
MD
printf '{"hash":"x","outcome":"filed","issues":["gh#5"],"ref":"refl","rel":[]}\n' > "$work/old-ledger.jsonl"
python3 -I "$P/scripts/_intake.py" parse "$work/old.md" "$work/old-ledger.jsonl" 10 > "$work/old.json"
check "intake parse: title, tags, handle and rel from the note" sh -c "python3 -c 'import json; n=json.load(open(\"$work/old.json\"))[\"notes\"][0]; assert (n[\"title\"],n[\"tags\"],n[\"ref\"],n[\"rel\"])==(\"Ball spins forever\",[\"bug\"],\"spin\",[\"refl\"]), n'"
check "intake parse: related notes carry the items already filed for them" sh -c "python3 -c 'import json; n=json.load(open(\"$work/old.json\"))[\"notes\"][0]; assert n[\"related\"]==[{\"ref\":\"refl\",\"issues\":[\"gh#5\"],\"outcome\":\"filed\"}], n'"
check "intake parse: a title ending in ? is a question, #dup names its handle, #parked is a plain tag" sh -c "python3 -c 'import json; n=json.load(open(\"$work/old.json\"))[\"notes\"]; assert n[1][\"question\"] and not n[0][\"question\"] and n[4][\"dup\"]==\"spin\" and n[4][\"ref\"]==\"spin2\" and n[2][\"tags\"]==[\"parked\"]'"
cat > "$work/bin/claude" <<'SH'
#!/bin/sh
printf '%s\t%s\t%s\n' "$0" "$PWD" "$*" >> "$HOST_LOG"
out="$(printf '%s' "$*" | sed -n 's/.* and write \(.*results\.json\)\. Unattended.*/\1/p')"
python3 -c "
import json, os, sys
d = json.load(open(os.path.join(os.path.dirname(sys.argv[1]), 'notes.json'))); n = d['notes'][0]
open(os.environ['HOST_LOG'], 'a').write('vocabulary %s %s\n' % (d['types'], d['areas']))
open(os.environ['HOST_LOG'], 'a').write('rules %s\n' % d['rules'])
row = {'note': n['id'], 'outcome': 'filed', 'issues': ['gh#9']}
if n['question']: row = {'note': n['id'], 'outcome': 'answered', 'issues': [], 'title': n['title'], 'answer': 'The ball gives it momentum.\n\nSee \`Rod.cs:12\`.'}
if 'Old' in n['title']: row = {'note': n['id'], 'outcome': 'dropped', 'issues': [], 'reason': 'The net settings were removed in gh#120.'}
if 'Vague' in n['title']: row = {'note': n['id'], 'outcome': 'dropped', 'issues': []}
json.dump([row], open(sys.argv[1], 'w'))" "$out"
SH
chmod +x "$work/bin/claude"
: > "$HOST_LOG"
FLOW_HOME="$home2" "$P/jobs/intake.sh" claude --notes "$work/old.md" > "$work/old.out" 2>&1
check "intake job: an answered question goes to the answers page, not the tracker" sh -c "grep -q '^# Answers' '$work/answers.md' && grep -q '^## Why does a free rod swing?' '$work/answers.md' && grep -q 'Rod.cs:12' '$work/answers.md' && grep -q 'From the notes (Bots), answered' '$work/answers.md' && ! grep -q 'free rod' '$work/old.md'"
check "intake job: a dropped note goes to the dropped page with its reason" sh -c "grep -q '^- \*\*Old net settings\*\* (Bots), .*: The net settings were removed in gh#120.' '$work/dropped.md' && ! grep -q 'Old net' '$work/old.md'"
check "intake job: a drop without a reason is kept" sh -c "grep -q 'Vague thing' '$work/old.md' && ! grep -q Vague '$work/dropped.md' && grep -q 'dropped without a reason, kept' '$home2/log/intake.log'"
check "intake job: the ledger keeps each note's handle and links for the notes after it" sh -c "grep '\"ref\": \"spin2\"' '$home2/log/intake-ledger.jsonl' | grep -q '\"rel\": \[\"spin\"\]'"
check "intake job: the summary counts answered and dropped" grep -q 'done: answered 1 dropped 1 filed 2 kept 1' "$work/old.out"
check "intake job: a tracker without types or areas sends empty lists" grep -q 'vocabulary \[\] \[\]' "$HOST_LOG"
check "intake job: without project rules each session gets flow's default rules" sh -c "grep -qx 'rules $P/skills/intake/rules.md' '$HOST_LOG' && [ -s '$P/skills/intake/rules.md' ]"
here="$(pwd)"; mkdir -p "$work/notesrepo" && cd "$work/notesrepo" && git init -q --bare origin.git && git clone -q origin.git app 2>/dev/null && cd app && git config user.email t@t && git config user.name t
mkdir -p docs .flow && cp "$work/notes.orig" docs/notes.md && printf -- '- How does a pin hold?\n' >> docs/notes.md && printf '.flow/\n' > .gitignore && git add -A && git commit -qm init && git push -q origin HEAD:main 2>/dev/null && git branch -q -M main && git branch -q -u origin/main
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\nnotify:\n  desktop: false\nintake:\n  notes: docs/notes.md\n' > .flow/config.yaml
"$P/jobs/intake.sh" claude > "$work/notesrepo.out" 2>&1
check "intake job: a tracked notes file is committed with its answers page, alone, and pushed" sh -c "git -C '$work/notesrepo/origin.git' log -1 --format=%s main | grep -q '^chore(notes)' && ! git -C '$work/notesrepo/origin.git' show main:docs/notes.md | grep -q 'First note' && git -C '$work/notesrepo/origin.git' show main:docs/answers.md | grep -q '^## How does a pin hold?' && [ \"\$(git -C '$work/notesrepo/origin.git' show --name-only --format= main | tr '\n' ' ')\" = 'docs/answers.md docs/notes.md ' ]"
printf 'x\n' > other.txt && git add other.txt && git commit -qm other && printf -- '- Fourth note\n' >> docs/notes.md
"$P/jobs/intake.sh" claude >> "$work/notesrepo.out" 2>&1
check "intake job: other unpushed commits hold the push back" sh -c "grep -q 'other unpushed changes' .flow/log/intake.log && ! git -C '$work/notesrepo/origin.git' log --format=%s main | grep -q '^other'"
cd "$here"
notes_clone() { # notes_clone <dir> <more intake config>: <dir>/origin.git and its clone <dir>/app, notes with a question
  mkdir -p "$1" && git init -q --bare "$1/origin.git" && git clone -q "$1/origin.git" "$1/app" 2>/dev/null && (cd "$1/app" &&
    git config user.email t@t && git config user.name t && mkdir -p docs .flow && cp "$work/notes.orig" docs/notes.md &&
    printf -- '- How does a pin hold?\n' >> docs/notes.md && printf '.flow/\n' > .gitignore && git add -A && git commit -qm init &&
    git push -q origin HEAD:main 2>/dev/null && git branch -q -M main && git branch -q -u origin/main &&
    printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\nnotify:\n  desktop: false\nintake:\n  notes: docs/notes.md\n%b' "$2" > .flow/config.yaml)
}
notes_clone "$work/notes repo" ""
(cd "$work/notes repo/app" && "$P/jobs/intake.sh" claude) > "$work/space.out" 2>&1
check "intake job: a repo path with a space still commits the notes and the page" sh -c "[ \"\$(git -C '$work/notes repo/origin.git' show --name-only --format= main | tr '\n' ' ')\" = 'docs/answers.md docs/notes.md ' ] && ! git -C '$work/notes repo/origin.git' show main:docs/notes.md | grep -q 'First note'"
notes_clone "$work/ignored" "  answers: .flow/answers.md\n"
(cd "$work/ignored/app" && "$P/jobs/intake.sh" claude) > "$work/ignored.out" 2>&1
check "intake job: an ignored answers page is left out and the notes are still committed" sh -c "[ \"\$(git -C '$work/ignored/origin.git' show --name-only --format= main)\" = docs/notes.md ] && grep -q 'pin hold' '$work/ignored/app/.flow/answers.md' && grep -q 'git ignores .flow/answers.md' '$work/ignored.out'"
notes_clone "$work/ownrules" ""
printf '# Our rules\n' > "$work/ownrules/app/.flow/intake.md"; : > "$HOST_LOG"
(cd "$work/ownrules/app" && "$P/jobs/intake.sh" claude) > /dev/null 2>&1
check "intake job: a project's .flow/intake.md is the rules each session gets" sh -c "grep -q '^rules .*/ownrules/app/.flow/intake.md\$' '$HOST_LOG' && ! grep -q 'skills/intake/rules.md' '$HOST_LOG'"
notes_clone "$work/badrules" "  rules: docs/missing-rules.md\n"; : > "$HOST_LOG"
(cd "$work/badrules/app" && "$P/jobs/intake.sh" claude) > "$work/badrules.out" 2>&1; code=$?
check "intake job: intake.rules naming a missing file fails before any session" sh -c "[ $code -ne 0 ] && grep -q 'intake.rules names .*missing-rules.md, which does not exist' '$work/badrules.out' && [ ! -s '$HOST_LOG' ]"
cat > "$work/batch.md" <<'MD'
## Batch

- Ball rolls off the rail ^bat1
- Rolls off again #dup (see ^bat1) ^bat2
- Gone rail guard ^bat3
- Guard again #dup (see ^bat3) ^bat4
- Speed grows as x^2 [^1] ^bat5
- Why does it bend?
MD
python3 -I "$P/scripts/_intake.py" parse "$work/batch.md" "$work/none.jsonl" 10 > "$work/batch.json"
check "intake parse: a caret inside a word or a footnote is not a handle" sh -c "python3 -c 'import json; n=json.load(open(\"$work/batch.json\"))[\"notes\"][4]; assert (n[\"title\"],n[\"ref\"])==(\"Speed grows as x^2 [^1]\",\"bat5\"), n'"
cat > "$work/bin/claude" <<'SH'
#!/bin/sh
out="$(printf '%s' "$*" | sed -n 's/.* and write \(.*results\.json\)\. Unattended.*/\1/p')"
python3 -c "
import json, os, sys
n = json.load(open(os.path.join(os.path.dirname(sys.argv[1]), 'notes.json')))['notes'][0]
open(os.environ['HOST_LOG'], 'a').write('related %s %s\n' % (n['ref'], json.dumps(n['related'], sort_keys=True)))
row = {'note': n['id'], 'outcome': 'filed', 'issues': ['gh#7' + n['id'][1:]]}
if 'Gone' in n['title']: row = {'note': n['id'], 'outcome': 'dropped', 'issues': [], 'reason': 'The rail\nwas removed.'}
if n['question']: row = {'note': n['id'], 'outcome': 'answered', 'issues': [], 'title': 'Why does it\n  bend?', 'answer': 'It bends.'}
json.dump([row], open(sys.argv[1], 'w'))" "$out"
SH
chmod +x "$work/bin/claude"
: > "$HOST_LOG"
FLOW_HOME="$home2" "$P/jobs/intake.sh" claude --notes "$work/batch.md" > "$work/batch.out" 2>&1
seen() { python3 -c 'import json,sys
for l in open(sys.argv[1]):
    if l.startswith("related %s " % sys.argv[2]): print(l.split(" ", 2)[2].strip())' "$HOST_LOG" "$1"; }
check "intake job: a #dup sees the item its target filed earlier in the same run" [ "$(seen bat2)" = '[{"issues": ["gh#71"], "outcome": "filed", "ref": "bat1"}]' ]
check "intake job: a #dup of a dropped note sees it dropped, with its reason" [ "$(seen bat4)" = '[{"issues": [], "outcome": "dropped", "reason": "The rail was removed.", "ref": "bat3"}]' ]
check "intake job: a model title with a newline gives a one-line heading" sh -c "grep -qx '## Why does it bend?' '$work/answers.md'"
check "jobs.permission_mode refuses anything but dontAsk or auto" sh -c "FLOW_PERMISSION_MODE=bypassPermissions FLOW_PLUGIN='$P' sh -c '. \"$P/lib/host.sh\"; host_permission_mode' 2>&1 | grep -q 'dontAsk or auto'"
printf '#!/bin/sh\nprintf "%%s\\t%%s\\t%%s\\n" "$0" "$PWD" "$*" >> "$HOST_LOG"\n' > "$work/bin/claude"; chmod +x "$work/bin/claude"

echo "new item and pool growth"
mkdir -p "$work/grow" && cd "$work/grow" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t
printf 'hi\n' > README.md && printf 'local\n' > .gitignore && printf 'secret\n' > local && git add -A && git commit -qm init
mkdir -p .flow
printf 'adapters:\n  default: local\nbase: main\npool:\n  # - ../app-wt-1\npool_max: 2\nworktree_copy:\n  - local\nworktree_setup:\n  - printf ran > setup.txt\nnotify:\n  desktop: false\n' > .flow/config.yaml
n1="$(printf '## Problem\nx\n## Acceptance\n- [ ] y\n' | "$P/scripts/new.sh" task "Grow the pool" --size S --body-file -)"
check_all "new: creates through the kind's adapter" '[ "$n1" = "local:task/1" ] && grep -q '\''^## Acceptance'\'' .flow/items/task/1.md'
check "new: bad kind refused" sh -c "! '$P/scripts/new.sh' story 'x' 2>/dev/null"
check "new: empty title refused" sh -c "! '$P/scripts/new.sh' task '' 2>/dev/null"
g1="$("$P/scripts/steward.sh" claim "$n1" 2>/dev/null)"
check_all "claim grows an empty pool" '[ "$g1" = "$(cd ../app-wt-1 && pwd -P)" ] && [ "$(git -C "$g1" symbolic-ref --short HEAD)" = "flow/local-task-1" ]'
check_all "the pool entry is appended, placeholder dropped" '[ "$(yaml_get .flow/config.yaml pool)" = ../app-wt-1 ] && ! grep -q '\''# - ../app-wt-1'\'' .flow/config.yaml && [ "$(yaml_get .flow/config.yaml pool_max)" = 2 ]'
check_all "worktree_copy and worktree_setup ran" '[ "$(cat "$g1/local")" = secret ] && [ "$(cat "$g1/setup.txt")" = ran ]'
n2="$("$P/scripts/new.sh" bug "Second")"
g2="$("$P/scripts/steward.sh" claim "$n2" 2>/dev/null)"
check_all "a second claim grows again, named after the last entry" '[ "$g2" = "$(cd ../app-wt-2 && pwd -P)" ] && [ "$(yaml_get .flow/config.yaml pool | wc -l | tr -d '\'' '\'')" = 2 ]'
n3="$("$P/scripts/new.sh" task "Third")"
"$P/scripts/steward.sh" claim "$n3" >/dev/null 2>&1; code=$?
check_all "at pool_max the claim fails (exit 3)" '[ "$code" -eq 3 ] && [ ! -d ../app-wt-3 ]'
rm "$g2/setup.txt"
check "setup re-runs on demand" sh -c "'$P/scripts/steward.sh' setup '$g2' >/dev/null && [ -f '$g2/setup.txt' ]"
"$P/scripts/steward.sh" add >/dev/null 2>&1
check_all "add without a path takes the next name" '[ -d ../app-wt-3 ] && [ "$(yaml_get .flow/config.yaml pool | tail -1)" = ../app-wt-3 ]'

echo "auto_gates"
mkdir -p "$work/auto" && cd "$work/auto" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t
printf 'hi\n' > README.md && git add -A && git commit -qm init && mkdir -p .flow
printf 'adapters:\n  default: local\nbase: main\npool:\npool_max: 2\nauto_gates:\n  plan-approval: S, M\nnotify:\n  desktop: false\n' > .flow/config.yaml
a1="$("$P/scripts/new.sh" task "Auto plan" --size M --body "## Acceptance
- [ ] x")"
for s in design plan; do "$P/scripts/next.sh" "$a1" >/dev/null 2>&1; ra="$(cat .flow/runs/local-task-1.json | jget reports)"; printf '{"status":"done","summary":"planned"}\n' > "$ra/$s.json"; "$P/scripts/advance.sh" "$a1" >/dev/null 2>&1; code=$?; done
check_all "plan-approval is auto-approved for a listed size" '[ "$code" -eq 0 ] && [ "$("$P/adapters/local/read.sh" "$a1" | jget state.step)" = "implement" ] && [ "$("$P/adapters/local/read.sh" "$a1" | jget state.gate)" != "plan-approval" ] && grep -q '\''auto-approved (size M)'\'' .flow/events.log'
a2="$("$P/scripts/new.sh" task "Big plan" --size L --body "## Acceptance
- [ ] x")"
for s in design plan; do "$P/scripts/next.sh" "$a2" >/dev/null 2>&1; rb2="$(cat .flow/runs/local-task-2.json | jget reports)"; printf '{"status":"done"}\n' > "$rb2/$s.json"; "$P/scripts/advance.sh" "$a2" >/dev/null 2>&1; code=$?; done
check_all "an unlisted size still stops at plan-approval" '[ "$code" -eq 4 ] && [ "$("$P/adapters/local/read.sh" "$a2" | jget state.gate)" = "plan-approval" ]'
printf 'adapters:\n  default: local\nbase: main\npool_max: 1\nauto_gates:\n  merge: S\n' > .flow/config.yaml
check "init: --check flags an auto gate that is not allowed" sh -c "FLOW_PLUGIN='$P' '$P/skills/init/scripts/init.sh' --check | grep -q 'gap: .flow/config.yaml: auto_gates lists merge'"
echo "a full pool: next skips what needs a new worktree"
mkdir -p "$work/full" && cd "$work/full" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t
printf 'hi\n' > README.md && git add -A && git commit -qm init && mkdir -p .flow
printf 'adapters:\n  default: local\nbase: main\npool:\npool_max: 1\nnotify:\n  desktop: false\n' > .flow/config.yaml
f1="$("$P/scripts/new.sh" task "Needs a worktree" --size S --body "## Acceptance
- [ ] a")"
f2="$("$P/scripts/new.sh" task "Holds a worktree" --size S --body "## Acceptance
- [ ] b")"
"$P/scripts/steward.sh" claim "$f2" >/dev/null 2>&1
out="$("$P/scripts/next.sh" --json 2>/dev/null)"; code=$?
check "a full pool: next takes the item that holds a claim, not exit 3" sh -c '[ "$1" -eq 0 ] && [ "$2" = "$3" ]' _ "$code" "$(printf '%s' "$out" | jget item)" "$f2"
"$P/scripts/next.sh" >/dev/null 2>&1; code=$?
check "a full pool with only unclaimed items left: exit 3, not 5" [ "$code" -eq 3 ]
check "the pick lock is released after a skipped pick" [ ! -d .flow/pick.lock ]
check "a skipped pick leaves no cached ready list behind" sh -c '! ls .flow/runs/.ready.* >/dev/null 2>&1'
rm -f ".flow/runs/$(item_slug "$f2").json"
out="$(FLOW_NEXT_SKIP="$f2" "$P/scripts/next.sh" --json 2>/dev/null)"; code=$?
check "a FLOW_NEXT_SKIP from the caller's environment is ignored" sh -c '[ "$1" -eq 0 ] && [ "$2" = "$3" ]' _ "$code" "$(printf '%s' "$out" | jget item)" "$f2"
"$P/scripts/next.sh" "$f1" >/dev/null 2>&1; code=$?
check "a named item that needs a worktree still exits 3" [ "$code" -eq 3 ]

echo "parallel runs: the pick lock and --workers"
mkdir -p "$work/par" && cd "$work/par" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t
printf 'hi\n' > README.md && git add -A && git commit -qm init && mkdir -p .flow
printf 'adapters:\n  default: local\nbase: main\npool:\npool_max: 3\nnotify:\n  desktop: false\n' > .flow/config.yaml
for t in one two; do "$P/scripts/new.sh" task "Parallel $t" --size S --body "## Acceptance
- [ ] $t" >/dev/null; done
"$P/scripts/next.sh" --json > "$work/p1.json" 2>/dev/null & q1=$!
"$P/scripts/next.sh" --json > "$work/p2.json" 2>/dev/null & q2=$!
wait "$q1"; wait "$q2"
i1="$(jget item < "$work/p1.json")"; i2="$(jget item < "$work/p2.json")"
w1="$(jget worktree < "$work/p1.json")"; w2="$(jget worktree < "$work/p2.json")"
check_all "two runs started together take two items" '[ -n "$i1" ] && [ -n "$i2" ] && [ "$i1" != "$i2" ]'
check_all "...in two worktrees" '[ -n "$w1" ] && [ "$w1" != "$w2" ]'
check "the pick lock is released after the pick" [ ! -d .flow/pick.lock ]
sleep 30 & held=$!
mkdir -p .flow/pick.lock && echo "$held" > .flow/pick.lock/pid
"$P/scripts/new.sh" task "Parallel three" --size S --body "## Acceptance
- [ ] three" >/dev/null
FLOW_LOCK_WAIT=1 "$P/scripts/next.sh" >/dev/null 2>&1; code=$?
check "a live holder makes the next pick wait, then exit 7 (quiet)" [ "$code" -eq 7 ]
kill "$held" 2>/dev/null; wait "$held" 2>/dev/null
FLOW_LOCK_WAIT=1 "$P/scripts/next.sh" >/dev/null 2>&1; code=$?
check_all "a stale lock (holder gone) is taken over" '[ "$code" -eq 0 ] && [ ! -d .flow/pick.lock ]'
for f in .flow/runs/*.json; do it="$(jget item < "$f")"; "$P/scripts/steward.sh" release "$it" --force >/dev/null 2>&1; mv "$f" "$f.done"; done
: > "$HOST_LOG"
"$P/jobs/next.sh" claude --workers 2 --max-steps 1 >/dev/null 2>&1
check_all "--workers 2: two loops, two logs" '[ -f .flow/log/next-1.log ] && [ -f .flow/log/next-2.log ]'
check "--workers 2: each worker ran a step in its own worktree" [ "$(cut -f2 "$HOST_LOG" | sort -u | grep -c .)" = 2 ]
check "--workers with an item is refused" sh -c "! '$P/jobs/next.sh' claude local:task/1 --workers 2 2>/dev/null"
check "--workers 0 is refused" sh -c "! '$P/jobs/next.sh' claude --workers 0 2>/dev/null"
cd "$repo"

echo "help"
check "help lists every skill" sh -c "for s in \$(ls '$P/skills'); do '$P/scripts/help.sh' | grep -q \"^| \$s |\" || exit 1; done"
check "help <skill> shows one" sh -c "'$P/scripts/help.sh' gate | grep -q '/flow:gate'"
check "help lines shows every profile" sh -c "'$P/scripts/help.sh' lines | grep -q 'task L' && '$P/scripts/help.sh' lines | grep -q '\[plan-approval\]'"
check "help gates names every gate" sh -c "for g in interview plan-approval decomposition feel-test merge escalation ambiguity; do '$P/scripts/help.sh' gates | grep -q \"\*\*\$g\*\*\" || exit 1; done"
check "help of an unknown skill fails" sh -c "! '$P/scripts/help.sh' nonesuch >/dev/null"
cd "$repo"

echo "prune"
pc="$("$P/adapters/local/create.sh" task "Pruned")"; "$P/adapters/local/close.sh" "$pc" >/dev/null
po="$("$P/adapters/local/create.sh" task "Still open")"
pk="$("$P/adapters/local/create.sh" task "Closed but claimed")"; wk="$("$P/scripts/steward.sh" claim "$pk")"; "$P/adapters/local/close.sh" "$pk" >/dev/null
for d in "$repo" "$(cd ../wt-1 && pwd)"; do mkdir -p "$d/.flow/reports/$(item_slug "$pc")" "$d/.flow/reports/$(item_slug "$po")" "$d/.flow/reports/298"; done
mkdir -p "$wk/.flow/reports/$(item_slug "$pk")"
out="$("$P/scripts/steward.sh" prune --dry-run 2>&1)"
check "prune: --dry-run names the closed item's folders and deletes nothing" sh -c "[ \"\$(printf '%s' '$out' | grep -c 'would remove .*/$(item_slug "$pc") ')\" = 2 ] && [ -d '$repo/.flow/reports/$(item_slug "$pc")' ]"
out="$("$P/scripts/steward.sh" prune 2>&1)"
check "prune: removes a closed item's reports in the main and pool worktrees" sh -c "[ ! -e '$repo/.flow/reports/$(item_slug "$pc")' ] && [ ! -e '../wt-1/.flow/reports/$(item_slug "$pc")' ]"
check "prune: keeps an open item's reports" [ -d "$repo/.flow/reports/$(item_slug "$po")" ]
check "prune: keeps a claimed item's reports even when closed" [ -d "$wk/.flow/reports/$(item_slug "$pk")" ]
check "prune: keeps and names a folder that is not an item's" sh -c "[ -d '$repo/.flow/reports/298' ] && printf '%s' '$out' | grep -q 'reports/298: not an item folder'"
check "reports: a claimed item's folder is in its worktree" [ "$("$P/scripts/steward.sh" reports "$pk")" = "$wk/.flow/reports/$(item_slug "$pk")" ]
check "reports: an unclaimed item's existing folder is found in the pool" [ "$("$P/scripts/steward.sh" reports "$po")" = "$(cd ../wt-1 && pwd -P)/.flow/reports/$(item_slug "$po")" ]
pn="$("$P/adapters/local/create.sh" task "No reports yet")"
check "reports: a new item's folder is made in the main worktree" sh -c "[ \"\$('$P/scripts/steward.sh' reports '$pn')\" = '$(cd "$repo" && pwd -P)/.flow/reports/$(item_slug "$pn")' ] && [ -d '$repo/.flow/reports/$(item_slug "$pn")' ]"
"$P/scripts/steward.sh" reports 298 >/dev/null 2>&1; code=$?
check "reports: a bare number is not an item id (exit 2)" [ "$code" -eq 2 ]
check "release: a closed item's reports go with it" sh -c "'$P/scripts/steward.sh' release '$pk' --force && [ ! -e '$wk/.flow/reports/$(item_slug "$pk")' ]"
"$P/scripts/steward.sh" claim "$po" >/dev/null 2>&1; wo="$("$P/scripts/steward.sh" find "$po")"
check "release: an open item's reports stay" sh -c "'$P/scripts/steward.sh' release '$po' --force && [ -d '$repo/.flow/reports/$(item_slug "$po")' ]"

echo "sweep"
# The fake gh answers pr view with the PR in its state file, whatever the URL. One pool
# worktree is free here, so each case claims it in turn.
fake_pr() { python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["pr"]={"number":90,"state":sys.argv[2],"isDraft":False,"mergedAt":None,"url":"https://gh/pull/90","headRefName":"","headRefOid":sys.argv[3],"baseRefName":"main"}; json.dump(d,open(p,"w"))' "$FAKE_GH_DIR/issues.json" "$1" "$2"; }
commit_in() { printf '%s\n' "$2" > "$1/$2.txt" && git -C "$1" add -- "$2.txt" && git -C "$1" commit -qm "$2" && git -C "$1" rev-parse HEAD; }
sc="$("$P/adapters/local/create.sh" task "Closed, claimed")"; wc_="$("$P/scripts/steward.sh" claim "$sc")"
"$P/adapters/local/close.sh" "$sc" >/dev/null
check "sweep --dry-run: names the closed item's worktree and touches nothing" sh -c "'$P/scripts/steward.sh' sweep --dry-run | grep -q '$sc: would release' && [ -f '$wc_/.flow/claim.json' ]"
printf 'x\n' > "$wc_/dirty.txt"
check "sweep: uncommitted changes keep the worktree" sh -c "'$P/scripts/steward.sh' sweep | grep -q '$sc: kept .*uncommitted' && [ -f '$wc_/.flow/claim.json' ]"
rm "$wc_/dirty.txt"
check "sweep: a closed item's worktree is released" sh -c "'$P/scripts/steward.sh' sweep | grep -q '$sc: released' && [ ! -f '$wc_/.flow/claim.json' ]"
sm="$("$P/adapters/local/create.sh" task "Merged PR")"; wm="$("$P/scripts/steward.sh" claim "$sm")"
tip="$(commit_in "$wm" merged)"; "$P/adapters/local/link-pr.sh" "$sm" https://gh/pull/90
"$P/scripts/gate.sh" raise "$sm" merge "Merge the PR." >/dev/null 2>&1
fake_pr OPEN "$tip"
check "sweep: an open PR keeps its worktree" sh -c "[ -z \"\$('$P/scripts/steward.sh' sweep)\" ] && [ -f '$wm/.flow/claim.json' ]"
fake_pr MERGED "$tip"
out="$("$P/scripts/steward.sh" sweep)"
check "sweep: a merged PR releases its worktree" sh -c "printf '%s' '$out' | grep -q '$sm: released .*pull/90 merged' && [ ! -f '$wm/.flow/claim.json' ]"
check "sweep: the merge gate clears with the PR" sh -c "[ \"\$('$P/adapters/local/read.sh' '$sm' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"state\"][\"gate\"])')\" = none ] && [ ! -f .flow/gates/$(item_slug "$sm").json ] && grep -q 'Gate cleared: merged: https://gh/pull/90' .flow/items/task/${sm##*/}.md"
check "sweep: the item closes when the merge did not close it" [ "$("$P/adapters/local/read.sh" "$sm" | jget status)" = closed ]
check "sweep: a squash-merged branch at the PR's head is deleted" sh -c "! git -C '$wm' show-ref --verify --quiet refs/heads/flow/$(item_slug "$sm")"
sl="$("$P/adapters/local/create.sh" task "Commit after merge")"; wl="$("$P/scripts/steward.sh" claim "$sl")"
merged_tip="$(commit_in "$wl" first)"; commit_in "$wl" later >/dev/null
"$P/adapters/local/link-pr.sh" "$sl" https://gh/pull/90; fake_pr MERGED "$merged_tip"
"$P/scripts/steward.sh" sweep >/dev/null 2>&1
check "sweep: a commit after the merge keeps the branch" sh -c "[ ! -f '$wl/.flow/claim.json' ] && git -C '$wl' show-ref --verify --quiet refs/heads/flow/$(item_slug "$sl")"
fake_pr OPEN ""

echo "health"
hroot="$work/health"; mkdir -p "$hroot"
git init -q --bare "$hroot/origin.git"
git clone -q "$hroot/origin.git" "$hroot/app" 2>/dev/null
cd "$hroot/app" || exit 1
git config user.email t@t && git config user.name t
git symbolic-ref HEAD refs/heads/main
printf 'hi\n' > README.md && git add -A && git commit -qm init && git push -q -u origin main
for n in 1 2 3; do git worktree add -q --detach "../wt-$n"; done
mkdir -p .flow
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\n  - ../wt-3\npool_max: 3\nnotify:\n  desktop: true\njobs:\n  schedule:\n    health: every 15m\n  health:\n    behind_base: 2\n' > .flow/config.yaml
git clone -q "$hroot/origin.git" "$hroot/other" 2>/dev/null
git -C "$hroot/other" config user.email t@t && git -C "$hroot/other" config user.name t
hs() { "$P/scripts/steward.sh" health "$@"; }
hitem() { "$P/adapters/local/create.sh" task "$1" --size S --body "x"; }
hold() { "$P/scripts/next.sh" "$1" >/dev/null && "$P/scripts/steward.sh" find "$1"; }
rec() { printf '%s/.flow/runs/%s.json' "$hroot/app" "$(item_slug "$1")"; }
age_run() { python3 -c '
import json, sys, time
p, pid = sys.argv[1], sys.argv[2]
d = json.load(open(p)); d["started"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 172800))
d.pop("pid", None)
if pid != "-": d["pid"] = int(pid)
json.dump(d, open(p, "w"))' "$(rec "$1")" "${2:-999999}"; }
stale_claim() { python3 -c '
import json, sys, time
p = sys.argv[1] + "/.flow/claim.json"
d = json.load(open(p)); d["claimed_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 172800)); json.dump(d, open(p, "w"))' "$1"
  find "$1/.flow/reports" -exec touch -t 202401010000 {} + 2>/dev/null; }
remote_commit() { git -C "$hroot/other" fetch -q origin && git -C "$hroot/other" checkout -q -B "$1" "origin/$1" && printf '%s\n' "$2" > "$hroot/other/$2.txt" && git -C "$hroot/other" add -- "$2.txt" && git -C "$hroot/other" commit -qm "$2" && git -C "$hroot/other" push -q origin "$1"; }
facts() { n="$(grep -c "$1" .flow/events.log 2>/dev/null)"; echo "${n:-0}"; }
pings() { n="$(grep -c 'flow: health' "$work/offline.log" 2>/dev/null)"; echo "${n:-0}"; }
printf '#!/bin/sh\nprintf "%%s\\t%%s\\n" "$PWD" "$*" >> "%s/host.log"\n' "$hroot" > "$work/bin/claude"; chmod +x "$work/bin/claude"
export FLOW_HEALTH_PROCS="$hroot/procs"; : > "$FLOW_HEALTH_PROCS"; : > "$work/offline.log"

hs > "$hroot/out" 2>&1
check "health: a healthy pool is one quiet line" sh -c "[ \$(wc -l < '$hroot/out' | tr -d ' ') = 1 ] && grep -q 'health: 0 claimed.*3 free.*nothing to do' '$hroot/out'"
"$P/jobs/health.sh" claude >/dev/null
check "health job: nothing to do is a quiet run with no event and no notification" sh -c "grep -q 'quiet: 0 claimed' .flow/log/health.log && tail -1 .flow/log/runs.jsonl | grep -q '\"result\":\"quiet' && [ ! -s .flow/events.log ] && [ \$(grep -c 'flow: health' '$work/offline.log') = 0 ]"
remote_commit main m1
hs > "$hroot/out" 2>&1
check "health: a free worktree follows the base branch tip" sh -c "[ \"\$(git -C ../wt-1 rev-parse HEAD)\" = \"\$(git rev-parse origin/main)\" ] && [ \"\$(git -C ../wt-3 rev-parse HEAD)\" = \"\$(git rev-parse origin/main)\" ] && grep -q 'fast-forwarded free wt-2' '$hroot/out'"
hs > "$hroot/out" 2>&1
check "health: a worktree already at the tip is not a finding" grep -q 'nothing to do' "$hroot/out"

fakeloop="$work/fake/run-unattended.sh"; mkdir -p "$work/fake"; printf '#!/bin/sh\nsleep 60\n' > "$fakeloop"; chmod +x "$fakeloop"
loop="$(sh -c '"$1" >/dev/null 2>&1 & echo $!' _ "$fakeloop")"
a="$(hitem "Empty claim")"; FLOW_RUN_PID="$loop" "$P/scripts/next.sh" "$a" >/dev/null; wa="$("$P/scripts/steward.sh" find "$a")"
check "next records the pid of the loop that owns the run" [ "$(jget pid < "$(rec "$a")")" = "$loop" ]
age_run "$a" "$loop"; stale_claim "$wa"
env -u FLOW_HEALTH_PROCS "$P/scripts/steward.sh" health > "$hroot/out" 2>&1
check "health: a record whose pid still runs the loop is alive, however old" sh -c "[ -f '$(rec "$a")' ] && [ -f '$wa/.flow/claim.json' ] && grep -q '1 claimed (1 running' '$hroot/out'"
check "board: a live run shows where it runs" sh -c "'$P/scripts/board.sh' | grep -q 'running on'"
pkill -P "$loop" 2>/dev/null; kill "$loop" 2>/dev/null; wait "$loop" 2>/dev/null
check "board: a record with no process is a dead run, not a running one" sh -c "'$P/scripts/board.sh' > '$hroot/board' && grep -q '(dead run)' '$hroot/board' && ! grep -q 'running on' '$hroot/board' && grep -q '^## Health' '$hroot/board' && grep -q 'dead run of implement' '$hroot/board'"
events_before="$(wc -l < .flow/events.log | tr -d ' ')"
hs --dry-run > "$hroot/out" 2>&1
check "health --dry-run: says what it would do and changes nothing" sh -c "grep -q 'would clear the dead run' '$hroot/out' && grep -q 'would release the empty claim' '$hroot/out' && [ -f '$(rec "$a")' ] && [ -f '$wa/.flow/claim.json' ] && [ \"\$(wc -l < .flow/events.log | tr -d ' ')\" = $events_before ]"
"$P/jobs/health.sh" claude >/dev/null
check "health: a dead run's record is cleared and logged" sh -c "[ ! -f '$(rec "$a")' ] && grep -q \"$a: dead run of implement cleared\" .flow/log/health.log && grep -q \"$a	health	dead run of implement cleared\" .flow/events.log"
check "health: an empty claim is released and the item is back with the tracker" sh -c "[ ! -f '$wa/.flow/claim.json' ] && [ -z \"\$('$P/adapters/local/read.sh' '$a' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"state\"].get(\"worktree\",\"\"))')\" ] && ! git -C '$wa' symbolic-ref -q HEAD && grep -q 'released the empty claim' .flow/log/health.log"
check_all "health job: a run that found something says so" 'tail -1 .flow/log/runs.jsonl | grep -q '\''"result":"done: '\'''

b="$(hitem "Has commits")"; wb="$(hold "$b")"; commit_in "$wb" work >/dev/null
age_run "$b"; stale_claim "$wb"; : > "$hroot/host.log"
hs --wait > "$hroot/out" 2>&1
check "health: a dead run with commits is resumed, never released" sh -c "[ -f '$wb/.flow/claim.json' ] && grep -q \"$b: resumed implement on claude (attempt 1 of 3)\" '$hroot/out' && grep -q 'Follow the brief' '$hroot/host.log' && [ \"\$(cat .flow/health/$(item_slug "$b").resume)\" = '1 implement' ]"
check "health: the resumed step's brief says where the dead run stopped" grep -q 'The previous run of step implement died' "$wb/.flow/reports/$(item_slug "$b")/brief-implement.md"
check "health: the resume note goes in that one brief and no later one" sh -c "[ ! -f '$wb/.flow/reports/$(item_slug "$b")/resume.md' ] && ! grep -qs 'previous run' '$wb/.flow/reports/$(item_slug "$b")/health.md'"
check "health: the resumed run logs to its own file, not the health log" sh -c "[ -f .flow/log/resume-$(item_slug "$b").log ] && ! grep -q 'Follow the brief' .flow/log/health.log"
c="$(hitem "Dirty tree")"; wc2="$(hold "$c")"; printf 'unsaved\n' > "$wc2/dirty.txt"
age_run "$c"; stale_claim "$wc2"; : > "$hroot/host.log"
hs --wait > "$hroot/out" 2>&1
check "health: a dirty tree is never released or reset, and its run resumes" sh -c "[ -f '$wc2/.flow/claim.json' ] && [ \"\$(cat '$wc2/dirty.txt')\" = unsaved ] && grep -q \"$c: resumed implement\" '$hroot/out' && grep -q \"$wc2\" '$hroot/host.log'"
d="$(hitem "Idle with commits")"; wd="$(hold "$d")"; commit_in "$wd" idle >/dev/null; rm -f "$(rec "$d")"; stale_claim "$wd"; : > "$hroot/host.log"
hs --wait > "$hroot/out" 2>&1
check "health: a claim with commits and no run is left to the next job" sh -c "[ -f '$wd/.flow/claim.json' ] && [ ! -s '$hroot/host.log' ] && ! grep -q \"$d\" '$hroot/out'"

for i in 2 3; do age_run "$b"; hs --wait > "$hroot/out" 2>&1; done
check "health: a step that keeps dying is resumed up to max_resumes times" [ "$(facts "$b.*resumed implement")" = 3 ]
age_run "$b"; hs --wait > "$hroot/out" 2>&1
check "health: after max_resumes it raises an escalation gate instead of looping" sh -c "[ \"\$('$P/adapters/local/read.sh' '$b' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"state\"][\"gate\"])')\" = escalation ] && [ -f .flow/gates/$(item_slug "$b").json ] && grep -q 'died 3 times in a row' '$hroot/out' && [ $(facts "$b.*resumed implement") = 3 ] && [ -f '$wb/.flow/claim.json' ]"
check "health: the escalation notifies" grep -q "$(printf '\t')escalation$(printf '\t')" .flow/events.log

printf '{"job":"next","at":"2026-10-20T10:00:00Z","seconds":1,"exit":0,"result":"quiet: no free worktree (the pool is at pool_max)"}\n' >> .flow/log/runs.jsonl
: > "$work/offline.log"
hs > "$hroot/out" 2>&1; hs > "$hroot/out2" 2>&1
check "health: a full pool that next cannot start in is said once, with who holds each worktree and why" sh -c "[ \$(grep -c 'the pool is full' .flow/events.log) = 1 ] && [ \$(grep -c 'flow: health' '$work/offline.log') = 1 ] && grep -q 'wt-1 holds $b: waiting at the escalation gate' '$hroot/out' && grep -q 'holds $c: .*dead run, resumed\\|holds $c: running' '$hroot/out' && grep -q 'holds $d: no run' '$hroot/out' && ! grep -q 'the pool is full' '$hroot/out2'"

bd="flow/$(item_slug "$d")"
git -C "$wd" push -q origin "$bd"; remote_commit "$bd" r1
hs > "$hroot/out" 2>&1
check "health: a clean branch only behind its remote is fast-forwarded" sh -c "[ \"\$(git -C '$wd' rev-parse HEAD)\" = \"\$(git -C '$hroot/other' rev-parse HEAD)\" ] && grep -q 'fast-forwarded $bd' '$hroot/out'"
commit_in "$wd" l1 >/dev/null
hs > "$hroot/out" 2>&1; hs > "$hroot/out2" 2>&1
check "health: by default a branch only ahead of its remote is said once and not pushed" sh -c "[ \"\$(git --git-dir='$hroot/origin.git' rev-parse refs/heads/$bd)\" != \"\$(git -C '$wd' rev-parse HEAD)\" ] && grep -q 'not pushed (jobs.health.push is off)' '$hroot/out' && ! grep -q 'not pushed' '$hroot/out2'"
cp .flow/config.yaml "$hroot/config.yaml"; printf '    push: true\n' >> .flow/config.yaml
hs > "$hroot/out" 2>&1; cp "$hroot/config.yaml" .flow/config.yaml
check "health: with jobs.health.push a clean branch only ahead of an existing remote branch is pushed" sh -c "[ \"\$(git --git-dir='$hroot/origin.git' rev-parse refs/heads/$bd)\" = \"\$(git -C '$wd' rev-parse HEAD)\" ] && grep -q 'pushed 1 commit' '$hroot/out'"
dr="$wd/.flow/reports/$(item_slug "$d")"; : > "$work/offline.log"
remote_commit main m2; remote_commit main m3; remote_commit main m4
hs > "$hroot/out" 2>&1; hs > "$hroot/out2" 2>&1
check "health: a clean branch far behind its base, with no PR, gets the base merged in and no notification" sh -c "git -C '$wd' merge-base --is-ancestor origin/main HEAD && grep -q 'merged origin/main into $bd (3 commits behind)' '$hroot/out' && ! grep -q 'merged origin/main' '$hroot/out2' && [ ! -f '$dr/sync.md' ] && ! grep -q 'flow: health' '$work/offline.log'"
"$P/adapters/local/write-state.sh" "$d" pr=https://github.com/o/r/pull/9 >/dev/null
remote_commit main m5; remote_commit main m6; remote_commit main m7
hs > "$hroot/out" 2>&1
check "health: a branch with a PR is not merged into: its conflicts are the comments job's" sh -c "! git -C '$wd' merge-base --is-ancestor origin/main HEAD && ! grep -q 'origin/main into $bd\|$bd needs' '$hroot/out' && [ ! -f '$dr/sync.md' ]"
"$P/adapters/local/write-state.sh" "$d" pr= >/dev/null
printf 'mine\n' > "$wd/README.md"; git -C "$wd" commit -qam mine
git -C "$hroot/other" checkout -q -B main origin/main && git -C "$hroot/other" pull -q origin main && printf 'theirs\n' > "$hroot/other/README.md" && git -C "$hroot/other" commit -qam theirs && git -C "$hroot/other" push -q origin main
pre="$(git -C "$wd" rev-parse HEAD)"
hs > "$hroot/out" 2>&1; hs > "$hroot/out2" 2>&1
check "health: a base merge that conflicts is aborted and handed to the sync step, with no notification" sh -c "[ \"\$(git -C '$wd' rev-parse HEAD)\" = '$pre' ] && [ -z \"\$(git -C '$wd' status --porcelain -- . ':!.flow')\" ] && [ \"\$(cat '$dr/sync.md')\" = origin/main ] && grep -q '$bd needs origin/main merged in' '$hroot/out' && ! grep -q 'needs origin/main' '$hroot/out2' && ! grep -q 'flow: health' '$work/offline.log'"
"$P/scripts/next.sh" "$d" >/dev/null
run_step="$(jget step < "$(rec "$d")")"; own="$("$P/adapters/local/read.sh" "$d" | jget state.step)"
check "health: the next run is the sync step, ahead of the item's own step" sh -c "grep -q '## The merge' '$dr/brief-sync.md' && grep -q '^- \`origin/main\`' '$dr/brief-sync.md' && grep -q 'Your own step is implement' '$dr/brief-sync.md' && [ '$run_step' = sync ] && [ '$own' = implement ]"
printf '{"status": "done", "summary": "merged origin/main"}\n' > "$dr/sync.json"
"$P/scripts/advance.sh" "$d" > "$hroot/out" 2>&1; code=$?
own="$("$P/adapters/local/read.sh" "$d" | jget state.step)"
check "health: a finished sync step drops the order and leaves the item on its own step" sh -c "[ $code = 0 ] && grep -q 'sync done -> implement' '$hroot/out' && [ ! -f '$dr/sync.md' ] && [ ! -f '$(rec "$d")' ] && [ '$own' = implement ]"
printf 'origin/main\n' > "$dr/sync.md"; "$P/scripts/next.sh" "$d" >/dev/null
printf '{"status": "fail", "summary": "tests red after the merge"}\n' > "$dr/sync.json"; "$P/scripts/advance.sh" "$d" >/dev/null 2>&1; code=$?
gate_now="$("$P/adapters/local/read.sh" "$d" | jget state.gate)"; own="$("$P/adapters/local/read.sh" "$d" | jget state.step)"
check "health: a failed sync step raises an escalation gate and keeps the order" sh -c "[ $code = 4 ] && [ '$gate_now' = escalation ] && [ '$own' = implement ] && [ -f '$dr/sync.md' ]"
"$P/scripts/gate.sh" clear "$d" "retry" >/dev/null 2>&1
commit_in "$wd" l2 >/dev/null; remote_commit "$bd" r2
local_tip="$(git -C "$wd" rev-parse HEAD)"; remote_tip="$(git --git-dir="$hroot/origin.git" rev-parse "refs/heads/$bd")"
hs > "$hroot/out" 2>&1
check "health: a diverged branch goes to the sync step with its remote first, and its history is left alone" sh -c "[ \"\$(head -1 '$dr/sync.md')\" = 'origin/$bd' ] && [ \"\$(tail -1 '$dr/sync.md')\" = origin/main ] && [ \"\$(git -C '$wd' rev-parse HEAD)\" = '$local_tip' ] && [ \"\$(git --git-dir='$hroot/origin.git' rev-parse refs/heads/$bd)\" = '$remote_tip' ]"

python3 -c '
import json, sys, time
p = sys.argv[1]; d = json.load(open(p)); d["time"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - 172800)); json.dump(d, open(p, "w"))' ".flow/gates/$(item_slug "$b").json"
: > "$work/offline.log"
hs > "$hroot/out" 2>&1; hs > "$hroot/out2" 2>&1
check "health: a branch waiting at a gate is not merged into" sh -c "! grep -q 'merged origin/main into flow/$(item_slug "$b")' .flow/events.log"
check "health: a gate waiting past the reminder interval is reminded once" sh -c "grep -q '$b: waiting 2d .* at the escalation gate' '$hroot/out' && ! grep -q 'at the escalation gate' '$hroot/out2' && [ \$(grep -c 'flow: health' '$work/offline.log') = 1 ]"
printf 'escalation 1\n' > ".flow/health/$(item_slug "$b").remind"
hs > "$hroot/out" 2>&1
check "health: the next interval reminds again" grep -q "$b: waiting 2d .* at the escalation gate" "$hroot/out"

rm -f "$wc2/dirty.txt"; "$P/scripts/steward.sh" release "$c" --force >/dev/null 2>&1
e="$(hitem "No remote branch")"; we="$(hold "$e")"; commit_in "$we" solo >/dev/null; rm -f "$(rec "$e")"; stale_claim "$we"
hs > "$hroot/out" 2>&1
check "health: a task branch with no remote counterpart is never pushed" sh -c "[ -z \"\$(git ls-remote --heads origin 'flow/$(item_slug "$e")')\" ] && [ -f '$we/.flow/claim.json' ]"
hs > "$hroot/out" 2>&1
check "health: a state it already said is not said again" grep -q 'nothing to do' "$hroot/out"
"$P/scripts/next.sh" "$e" >/dev/null; age_run "$e" -
printf '4242\t\tclaude -p Follow the brief. Work in %s.\n' "$we" > "$FLOW_HEALTH_PROCS"
hs --wait > "$hroot/out" 2>&1
check "health: a record with no pid is alive while a process names its worktree" sh -c "[ -f '$(rec "$e")' ] && ! grep -q 'dead run' '$hroot/out'"
printf '7671\t\tclaude daemon run --spawned-by {"cwd":"%s"}\n4243\t\tvim %s/README.md\n4244\t\ttail -f %s/log\n' "$we" "$we" "$we" > "$FLOW_HEALTH_PROCS"
hs --wait > "$hroot/out" 2>&1
check "health: the same record is a dead run once only a daemon, an editor or a tail names it" grep -q "$e: dead run of implement cleared" "$hroot/out"
: > "$FLOW_HEALTH_PROCS"
hs --wait > "$hroot/out" 2>&1
check "health: a record younger than the grace is left alone, whatever its pid" sh -c "[ -f '$(rec "$e")' ] && [ $(facts "$e.*resumed implement") = 1 ]"
rm -f "$wd/.flow/reports/$(item_slug "$d")/sync.md"; "$P/scripts/steward.sh" release "$d" --force >/dev/null 2>&1
g="$(hitem "Empty at a gate")"; wg="$(hold "$g")"; "$P/scripts/gate.sh" raise "$g" ambiguity "Which one?" >/dev/null 2>&1; stale_claim "$wg"
hs > "$hroot/out" 2>&1
check "health: an empty claim waiting at a gate is not released" sh -c "[ -f '$wg/.flow/claim.json' ] && ! grep -q 'released the empty claim' '$hroot/out'"
"$P/scripts/gate.sh" clear "$g" answered >/dev/null 2>&1; stale_claim "$wg"
grep -v "$(printf '\t')$g$(printf '\t')" .flow/events.log > "$hroot/events" || true; cp "$hroot/events" .flow/events.log
(cd "$wg" && exec bash -c 'exec -a claude sleep 30') >/dev/null 2>&1 & agent=$!
sleep 1
env -u FLOW_HEALTH_PROCS "$P/scripts/steward.sh" health > "$hroot/out" 2>&1
check "health: an empty claim with an agent working in its worktree is not released" sh -c "[ -f '$wg/.flow/claim.json' ] && ! grep -q 'released the empty claim' '$hroot/out'"
kill "$agent" 2>/dev/null; wait "$agent" 2>/dev/null
env -u FLOW_HEALTH_PROCS "$P/scripts/steward.sh" health > "$hroot/out" 2>&1
check "health: the same claim is released once the agent is gone" sh -c "[ ! -f '$wg/.flow/claim.json' ] && grep -q 'released the empty claim' '$hroot/out'"
h="$(hitem "No ps")"; wh="$(hold "$h")"; age_run "$h"; stale_claim "$wh"
mkdir -p "$work/nops"; printf '#!/bin/sh\nexit 1\n' > "$work/nops/ps"; chmod +x "$work/nops/ps"
PATH="$work/nops:$PATH" env -u FLOW_HEALTH_PROCS "$P/scripts/steward.sh" health > "$hroot/out" 2>&1
check "health: with no process list no run is judged dead and no claim is released" sh -c "[ -f '$(rec "$h")' ] && [ -f '$wh/.flow/claim.json' ] && grep -q 'cannot list processes' '$hroot/out' && ! grep -q 'dead run\\|released\\|resumed' '$hroot/out'"
rm -f "$(rec "$h")"; "$P/scripts/steward.sh" release "$h" --force >/dev/null 2>&1
"$P/scripts/jobs.sh" pause health >/dev/null; : > .flow/events.log
"$P/jobs/health.sh" claude | grep -q paused
check "health job: a paused job does nothing" [ ! -s .flow/events.log ]
"$P/scripts/jobs.sh" resume health >/dev/null
check "jobs: status lists the health job with its schedule" sh -c "'$P/scripts/jobs.sh' status | grep -q '^| health | every 15m'"
check "jobs: cron gets the health line" sh -c "FLOW_SCHEDULER=cron '$P/scripts/jobs.sh' install health | grep -q '^\*/15 \* \* \* \* .*\.flow/jobs/health\.sh claude'"
check "jobs: history and logs take the health job" sh -c "'$P/scripts/jobs.sh' history health 3 | grep -q 'quiet\|work' && '$P/scripts/jobs.sh' logs health 3 | grep -q 'health.log'"
unset FLOW_HEALTH_PROCS
cd "$repo"

# --- init: stamp, guard, session-start nudge (on a copy of the plugin, so the plugin can change). The fake gh stays on PATH; init tolerates it.
plugin_copy="$work/plugin"; cp -R "$P" "$plugin_copy"; rm -rf "$plugin_copy/evals/results"
init="$plugin_copy/skills/init/scripts/init.sh"; start="$plugin_copy/hooks/session-start.sh"
mkdir -p "$work/fresh" && cd "$work/fresh" && git init -q -b main && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init
check "init: a fresh install writes the stamp" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' >/dev/null && grep -q '^source	' .flow/stamp && grep -q '	.codex/rules/flow.rules' .flow/stamp && ! grep -q 'notify.sh' .flow/stamp"
check "init: --check is clean after install" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'up to date'"
check "init: the fresh config has an empty model and effort pair per host, and no old jobs.model" sh -c "for k in claude.model claude.effort codex.model codex.effort; do grep -q \"^  \${k%%.*}:\" .flow/config.yaml || exit 1; [ -z \"\$(. '$P/lib/flow.sh'; yaml_get .flow/config.yaml jobs.\$k)\" ] || exit 1; done; ! grep -q '^  model:' .flow/config.yaml && grep -q 'Empty means the host.s own default' .flow/config.yaml"
cp .flow/config.yaml "$work/fresh.config"
sed -i.bak '/^  claude:$/,/^    effort:/d; /^  codex:$/,/^    effort:/d' .flow/config.yaml && rm -f .flow/config.yaml.bak
check "init: --check does not ask for the jobs.<host> keys on an existing project" sh -c "! grep -q '^  claude:' .flow/config.yaml && FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'up to date'"
awk '{ print } /^jobs:$/ { print "  host: vim"; print "  model: opus"; print "  effort: high" }' .flow/config.yaml > "$work/cfg.tmp" && cp "$work/cfg.tmp" .flow/config.yaml
hostline="$(grep -n '^  host: vim' .flow/config.yaml | cut -d: -f1)"
FLOW_PLUGIN="$plugin_copy" "$init" --check > "$work/init.out" 2>&1; code=$?
check "init: --check flags a jobs.host other than claude or codex as drift, with its line" sh -c "[ $code = 1 ] && grep -q 'gap: .flow/config.yaml:$hostline: jobs.host is vim; it must be claude or codex' '$work/init.out'"
check "init: --check says once that jobs.model and jobs.effort are deprecated" [ "$(grep -c 'jobs.model and jobs.effort are deprecated' "$work/init.out")" = 1 ]
sed -i.bak 's/^  host: vim$/  host: codex/; s/^  effort: high$/  effort: max/' .flow/config.yaml && rm -f .flow/config.yaml.bak
check "init: --check flags an effort the jobs host does not take" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'gap: .flow/config.yaml:[0-9]*: jobs.effort is max; codex takes low, medium, high or xhigh'"
cp "$work/fresh.config" .flow/config.yaml
check "init: installs the health job wrapper, its default schedule and its state folder in the gitignore" sh -c "[ -x .flow/jobs/health.sh ] && [ \"\$(. '$P/lib/flow.sh'; yaml_get .flow/config.yaml jobs.schedule.health)\" = 'every 15m' ] && grep -q '^.flow/health/' .gitignore && grep -q 'health: true' .flow/config.yaml"
mkdir -p .flow/answers.lock && echo $$ > .flow/answers.lock/pid
check "init: the gitignore block covers the lock directories, so answers.lock is not untracked" sh -c "grep -qxF '.flow/*.lock/' .gitignore && [ -z \"\$(git status --porcelain --untracked-files=all -- .flow/answers.lock)\" ]"
rm -rf .flow/answers.lock
sed -i.bak '/^\.flow\/\*\.lock\/$/d' .gitignore && rm -f .gitignore.bak
check "init: --check names a flow block that lacks the lock directories" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'drift: .gitignore: the flow block lacks .flow/\*.lock/'"
check "init: a refresh adds the lock line back" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' >/dev/null && grep -qxF '.flow/*.lock/' .gitignore && FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'up to date'"
check "init: the fresh config asks codex and claude for reviews" [ "$(FLOW_PLUGIN="$plugin_copy" "$plugin_copy/scripts/comments.sh" reviewers | tr '\n' ' ')" = "codex claude " ]
check "session-start: silent when the stamp matches" sh -c "[ -z \"\$(echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start')\" ]"
printf '# mine\n' >> .flow/notify.sh
check "init: a wrapper is replaced without a guard" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' >/dev/null && ! grep -q '# mine' .flow/notify.sh"
check "init: no wrapper holds the plugin path" sh -c "! grep -rqF '$plugin_copy' .flow/plugin.sh .flow/notify.sh .flow/run-unattended.sh .flow/jobs .flow/hooks"
fake_flow() { # fake_flow <home> <host dir> <version>: a stub flow whose scripts print the version
  d="$1/$2/plugins/cache/m/flow/$3"; mkdir -p "$d/scripts" "$d/jobs" "$d/hooks"
  for f in scripts/next.sh scripts/notify.sh jobs/next.sh hooks/worktree-create.sh; do printf '#!/bin/sh\necho %s\n' "$3" > "$d/$f"; chmod +x "$d/$f"; done
}
fake_flow "$work/h1" .claude 1.9.0; fake_flow "$work/h1" .claude 1.10.0; fake_flow "$work/h1" .codex 2.0.0
fake_flow "$work/h2" .codex 1.4.0
check "plugin.sh: the newest Claude version wins (1.10.0 over 1.9.0)" [ "$(env -u FLOW_PLUGIN HOME="$work/h1" .flow/notify.sh)" = "1.10.0" ]
check "plugin.sh: the job and hook wrappers find it too" sh -c "[ \"\$(env -u FLOW_PLUGIN HOME='$work/h1' .flow/jobs/next.sh)\" = 1.10.0 ] && [ \"\$(env -u FLOW_PLUGIN HOME='$work/h1' .flow/hooks/worktree-create.sh)\" = 1.10.0 ]"
check "plugin.sh: the Codex cache when Claude has none" [ "$(env -u FLOW_PLUGIN HOME="$work/h2" .flow/notify.sh)" = "1.4.0" ]
check "plugin.sh: FLOW_PLUGIN wins" [ "$(FLOW_PLUGIN="$work/h2/.codex/plugins/cache/m/flow/1.4.0" HOME="$work/h1" .flow/notify.sh)" = "1.4.0" ]
mkdir -p "$work/h3"; env -u FLOW_PLUGIN HOME="$work/h3" .flow/notify.sh >/dev/null 2>&1; code=$?
check "plugin.sh: no installed plugin exits 2" [ "$code" -eq 2 ]
before="$(head -1 .flow/stamp)"
sed -i.bak 's/"version": "[^"]*"/"version": "9.9.9"/' "$plugin_copy/.claude-plugin/plugin.json" && rm -f "$plugin_copy/.claude-plugin/plugin.json.bak"
check "a version bump alone: the stamp source holds and session-start is silent" sh -c "[ \"\$(FLOW_PLUGIN='$plugin_copy' '$init' --source-hash)\" = \"\$(printf '%s' '$before' | cut -f2)\" ] && [ -z \"\$(echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start')\" ]"
printf '# mine\n' >> .codex/rules/flow.rules
check "init: --check names a hand edit" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'edited by hand: .codex/rules/flow.rules'"
check "init: refuses to replace a hand edit (exit 1, file kept)" sh -c "! FLOW_PLUGIN='$plugin_copy' '$init' >/dev/null && grep -q '# mine' .codex/rules/flow.rules"
check "init: --force replaces it" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' --force >/dev/null && ! grep -q '# mine' .codex/rules/flow.rules && FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'up to date'"
printf '\n# changed\n' >> "$plugin_copy/templates/flow.rules"
check "session-start: nudges when the plugin changed" sh -c "echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start' | grep -q 'behind flow v' && echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start' | grep -q 'drift: .codex/rules/flow.rules'"
check "init: refresh brings the stamp back in step" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' >/dev/null && [ -z \"\$(echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start')\" ]"
mkdir -p .claude && printf '{}\n' > .claude/settings.json
check "init: --check flags missing Claude worktree hooks as a gap" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'gap: .claude/settings.json: no WorktreeCreate'"
check "session-start: names missing Claude worktree hooks" sh -c "echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start' | grep -q 'no flow worktree hooks'"
printf '{"hooks":{"WorktreeCreate":[{"hooks":[{"type":"command","command":".flow/hooks/worktree-create.sh"}]}],"WorktreeRemove":[{"hooks":[{"type":"command","command":".flow/hooks/worktree-remove.sh"}]}]}}\n' > .claude/settings.json
check "init: --check is clean once the hooks are in the settings" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'up to date'"
check "session-start: silent once the hooks are in the settings" sh -c "[ -z \"\$(echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start')\" ]"
rm -rf .claude
rm .flow/stamp
check "session-start: no stamp asks for one init" sh -c "echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start' | grep -q 'no install stamp'"
printf 'adapters:\n  default: local\nbase: main\npool:\npool_max: 0\n' > .flow/config.yaml
check "init: --check flags an empty pool with pool_max 0 as a gap" sh -c "! FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'up to date' && FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'gap: .flow/config.yaml: the pool is empty'"
check "init: lists the gap after an install" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' | grep -q 'Gaps'"
mkdir -p "$work/plain" && cd "$work/plain" && git init -q
check "session-start: silent in a project without the flow" sh -c "[ -z \"\$(echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start')\" ]"

echo "init: a long pool, and the Slack webhook from the environment"
mkdir -p "$work/bigpool" && cd "$work/bigpool" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init
for n in 1 2 3 4 5; do git worktree add -q "../app-wt-$n" -b "wt$n" >/dev/null 2>&1; done
out="$(FLOW_PLUGIN="$plugin_copy" "$init" 2>&1)"
check "init: more worktrees than three raise pool_max to match" sh -c "grep -qx 'pool_max: 5' .flow/config.yaml && [ \"\$(grep -c '^  - ../app-wt-' .flow/config.yaml)\" = 5 ]"
check "init: says every listed worktree becomes a task slot" sh -c "printf '%s' '$out' | grep -q '5 worktrees already exist'"
mkdir -p "$work/fakebin" && printf '#!/bin/sh\necho "$@" >> "%s/curl.log"\n' "$work" > "$work/fakebin/curl" && chmod +x "$work/fakebin/curl"
printf 'adapters:\n  default: local\nbase: main\npool_max: 1\nnotify:\n  desktop: false\n  slack_webhook: https://config.example/hook\n' > .flow/config.yaml
: > "$work/curl.log"
PATH="$work/fakebin:$PATH" "$P/scripts/notify.sh" merge local:task/1 "ready" >/dev/null 2>&1
check "notify: the config webhook is the fallback" sh -c "grep -q 'config.example/hook' '$work/curl.log'"
: > "$work/curl.log"
PATH="$work/fakebin:$PATH" FLOW_SLACK_WEBHOOK=https://env.example/hook "$P/scripts/notify.sh" merge local:task/1 "ready" >/dev/null 2>&1
check "notify: FLOW_SLACK_WEBHOOK wins over the config" sh -c "grep -q 'env.example/hook' '$work/curl.log' && ! grep -q 'config.example' '$work/curl.log'"
printf 'adapters:\n  default: local\nbase: main\npool_max: 1\nnotify:\n  desktop: false\n' > .flow/config.yaml
: > "$work/curl.log"
PATH="$work/fakebin:$PATH" FLOW_SLACK_WEBHOOK=https://env.example/hook "$P/scripts/notify.sh" merge local:task/1 "ready" >/dev/null 2>&1
check "notify: the variable alone is enough, with no URL in the config" sh -c "grep -q 'env.example/hook' '$work/curl.log'"

echo "decomposition: a split parent and its children"
mkdir -p "$work/split" && cd "$work/split" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t
printf 'hi\n' > README.md && printf '.flow/\n' > .gitignore && git add -A && git commit -qm init
for n in 1 2 3; do git worktree add -q --detach "../app-wt-$n"; done
mkdir -p .flow && printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../app-wt-1\n  - ../app-wt-2\n  - ../app-wt-3\nnotify:\n  desktop: false\n' > .flow/config.yaml
export FLOW_HEALTH_PROCS="$work/split.procs"; : > "$FLOW_HEALTH_PROCS"
sread() { "$P/adapters/local/read.sh" "$1" | jget "$2"; }
# plan_step <item> <mode> <status json> <child>...: run the item's plan step: plan.md in <mode>,
# the children made with --parent, the result file written; prints the worktree. advance is left
# to the caller.
plan_step() {
  ps_item="$1"; ps_mode="$2"; ps_result="$3"; shift 3
  "$P/adapters/local/write-state.sh" "$ps_item" step=plan >/dev/null
  ps_out="$("$P/scripts/next.sh" "$ps_item" --json)"; ps_rep="$(printf '%s' "$ps_out" | jget reports)"
  printf '# plan\nDecomposition: %s\n' "$ps_mode" > "$ps_rep/plan.md"
  for ps_kid in "$@"; do "$P/scripts/new.sh" task "$ps_kid" --size S --parent "$ps_item" --body x >/dev/null 2>&1; done
  printf '%s\n' "$ps_result" > "$ps_rep/plan.json"
  printf '%s' "$ps_out" | jget worktree
}
par="$("$P/scripts/new.sh" task "Split me" --size M --priority P1 --area Bots --body x)"
wp="$(plan_step "$par" "tracker tasks (each phase is a PR)" '{"status":"gate","gate":"decomposition","message":"Two children."}')"
printf 'adr\n' > "$wp/adr.md" && git -C "$wp" add adr.md && git -C "$wp" commit -qm "docs: the ADR the children need"
k1="$("$P/scripts/new.sh" task "Child one" --size S --parent "$par" --body x 2>"$work/split.err")"
k2="$("$P/scripts/new.sh" task "Child two" --size S --priority P0 --parent "$par" --body x 2>/dev/null)"
check "new: a child takes its parent's priority and area" [ "$(sread "$k1" priority) $(sread "$k1" area)" = "P1 Bots" ]
check "new: the inheritance is said on stderr" grep -q "$k1 takes priority P1, area Bots from its parent $par" "$work/split.err"
check "new: a child that names its own priority keeps it, and still takes the area" [ "$(sread "$k2" priority) $(sread "$k2" area)" = "P0 Bots" ]
check "local: an item counts its open children" [ "$(sread "$par" open_children)" = 2 ]
"$P/scripts/advance.sh" "$par" > "$work/split.out" 2>&1; code=$?
check "split: a plan step ending in tracker tasks with children splits the item (exit 4)" sh -c "[ $code -eq 4 ] && [ \"\$('$P/adapters/local/read.sh' '$par' | python3 -c 'import json,sys; s=json.load(sys.stdin)[\"state\"]; print(s[\"step\"], s[\"gate\"])')\" = 'split decomposition' ]"
check "split: the decomposition gate tells the owner how to keep it whole" grep -q 'To keep it whole instead, close its children, then clear the gate' .flow/gates/local-task-1.json
check "split: the parent's clean worktree goes back to the pool" sh -c "[ ! -f '$wp/.flow/claim.json' ] && [ -z \"\$('$P/scripts/steward.sh' find '$par')\" ] && [ -z \"\$('$P/adapters/local/read.sh' '$par' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"state\"][\"worktree\"])')\" ]"
check "split: a branch with commits past the base is kept, and the event says so" sh -c "git show-ref --verify --quiet refs/heads/flow/local-task-1 && grep -q '	$par	split	.*released app-wt-1; flow/local-task-1 keeps its 1 commit(s) past main' .flow/events.log"
check "split: the parent is commented on" grep -q 'Split: split into 2 open child item(s)' .flow/items/task/1.md
"$P/scripts/gate.sh" clear "$par" "go" > "$work/split.out" 2>&1
check "split: clearing the gate with children open leaves it split" sh -c "[ \"\$('$P/adapters/local/read.sh' '$par' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"state\"][\"step\"])')\" = split ] && grep -q 'run next' '$work/split.out'"
"$P/scripts/next.sh" "$par" > /dev/null 2> "$work/split.err"; code=$?
check "split: next on the parent waits on its children (exit 4)" sh -c "[ $code -eq 4 ] && grep -q 'is split and waits on its 2 open child item(s)' '$work/split.err'"
check "split: the parent is never ready, the children are" sh -c "'$P/adapters/local/list-ready.sh' | python3 -c 'import json,sys; ids=[i[\"id\"] for i in json.load(sys.stdin)]; assert \"$par\" not in ids and \"$k1\" in ids and \"$k2\" in ids, ids'"
check "board: a split parent shows it waits on its children, not plan" sh -c "'$P/scripts/board.sh' | grep -q '| $par | task | P1 | M | Split me | split, waiting on 2 children |'"
"$P/adapters/local/close.sh" "$k1" >/dev/null; "$P/adapters/local/close.sh" "$k2" >/dev/null
"$P/scripts/next.sh" "$par" > /dev/null 2> "$work/split.err"; code=$?
check "split: once every child is closed, next says to close the parent (exit 6)" sh -c "[ $code -eq 6 ] && grep -q 'every child is closed' '$work/split.err'"
"$P/scripts/steward.sh" health > "$work/split.out" 2>&1; "$P/scripts/steward.sh" health >> "$work/split.out" 2>&1
check "health: a split parent with every child closed is said once" sh -c "[ \"\$(grep -c '$par: split, and every child is closed: close it' '$work/split.out')\" = 1 ]"
# The owner keeps a split item whole: closes the children, then clears the gate.
wh="$("$P/scripts/new.sh" task "Keep me whole" --size M --body x)"
plan_step "$wh" "tracker tasks" '{"status":"gate","gate":"decomposition","message":"One child."}' "Whole child" >/dev/null
"$P/scripts/advance.sh" "$wh" >/dev/null 2>&1
"$P/adapters/local/close.sh" "$(grep -l 'title: Whole child' .flow/items/task/*.md | sed 's|.*/\([0-9]*\)\.md|local:task/\1|')" >/dev/null
check "split: an owner who closed the children and cleared the gate gets the plan step back" sh -c "'$P/scripts/gate.sh' clear '$wh' 'keep it whole' | grep -q 'whole again' && [ \"\$('$P/adapters/local/read.sh' '$wh' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"state\"][\"step\"])')\" = plan ]"
wwh="$("$P/scripts/steward.sh" claim "$wh")"
"$P/scripts/new.sh" task "Follow-up of a whole item" --size S --parent "$wh" --body x >/dev/null 2>&1
"$P/scripts/steward.sh" health >/dev/null 2>&1
check "split: a kept-whole item with its old tracker-tasks plan and a new child is not split again" sh -c "[ -f '$wwh/.flow/claim.json' ] && [ \"\$('$P/adapters/local/read.sh' '$wh' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"state\"][\"step\"])')\" = plan ] && '$P/scripts/steward.sh' split '$wh' | grep -q 'the owner kept it whole'"
wout="$("$P/scripts/next.sh" "$wh" --json)"; wrep="$(printf '%s' "$wout" | jget reports)"
printf '# plan\nDecomposition: tracker tasks (rewritten after the owner kept it whole)\n' > "$wrep/plan.md"
printf '{"status":"done","summary":"two PRs after all"}\n' > "$wrep/plan.json"
"$P/scripts/advance.sh" "$wh" >/dev/null 2>&1
check "split: once the plan step rewrites plan.md the mark is gone and the split stands" [ "$(sread "$wh" state.step)" = split ]
am="$("$P/scripts/new.sh" task "Asks first" --size M --body x)"
wam="$(plan_step "$am" "tracker tasks" '{"status":"gate","gate":"ambiguity","message":"1. Which base?"}' "Asking child")"
"$P/scripts/advance.sh" "$am" >/dev/null 2>&1
check "split: a plan step stopping at an ambiguity gate does not split" sh -c "[ -f '$wam/.flow/claim.json' ] && [ \"\$('$P/adapters/local/read.sh' '$am' | python3 -c 'import json,sys; s=json.load(sys.stdin)[\"state\"]; print(s[\"step\"], s[\"gate\"])')\" = 'plan ambiguity' ]"
"$P/scripts/gate.sh" clear "$am" "main" >/dev/null 2>&1; "$P/scripts/steward.sh" release "$am" --force >/dev/null 2>&1
# A child filed by hand and a plan in local phases (the gate raised before the planner made any):
# the owner's answer "keep it whole" never splits it.
lp="$("$P/scripts/new.sh" task "Local phases" --size M --body x)"
wl="$(plan_step "$lp" "local phases" '{"status":"gate","gate":"decomposition","message":"Approve the split before the items are created."}' "Stray follow-up")"
"$P/scripts/advance.sh" "$lp" >/dev/null 2>&1
"$P/scripts/gate.sh" clear "$lp" "keep it whole" >/dev/null 2>&1
check "split: children exist but the plan is not tracker tasks and the owner said keep it whole: not split" sh -c "[ -f '$wl/.flow/claim.json' ] && [ \"\$('$P/adapters/local/read.sh' '$lp' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"state\"][\"step\"])')\" = plan ]"
check "split: the steward refuses a plan that is not tracker tasks" sh -c "! '$P/scripts/steward.sh' split '$lp' | grep -q released && '$P/scripts/steward.sh' split '$lp' | grep -q 'does not say tracker tasks'"
"$P/scripts/steward.sh" release "$lp" --force >/dev/null 2>&1
# A dirty worktree is never reset: it stays claimed, the claim says split, and the event says why.
dp="$("$P/scripts/new.sh" task "Dirty split" --size M --body x)"
wd="$(plan_step "$dp" "tracker tasks" '{"status":"done","summary":"two PRs"}' "Dirty child")"
printf 'wip\n' > "$wd/wip.txt"
"$P/scripts/advance.sh" "$dp" >/dev/null 2>&1; code=$?
check "split: a plan step done in tracker tasks splits with no gate (exit 4)" sh -c "[ $code -eq 4 ] && [ \"\$('$P/adapters/local/read.sh' '$dp' | python3 -c 'import json,sys; s=json.load(sys.stdin)[\"state\"]; print(s[\"step\"], s[\"gate\"])')\" = 'split none' ]"
check "split: a dirty worktree is kept, its change untouched, the claim says split, and the event says why" sh -c "[ -f '$wd/wip.txt' ] && [ \"\$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[\"step\"])' '$wd/.flow/claim.json')\" = split ] && grep -q '	$dp	split	.*is kept: it has uncommitted changes' .flow/events.log"
lines="$(grep -c "	$dp	split	" .flow/events.log)"
"$P/scripts/steward.sh" split "$dp" >/dev/null; "$P/scripts/steward.sh" health > "$work/split.out" 2>&1
check "split: asking again while still dirty says nothing new" [ "$(grep -c "	$dp	split	" .flow/events.log)" = "$lines" ]
rm "$wd/wip.txt"
"$P/scripts/steward.sh" health > "$work/split.out" 2>&1
check "health: a split whose worktree is clean now is released" sh -c "[ ! -f '$wd/.flow/claim.json' ] && grep -q '$dp: split into 1 open child item(s), it waits on them; released' '$work/split.out'"
# A live session in the worktree keeps it.
lv="$("$P/scripts/new.sh" task "Live session" --size M --body x)"
wv="$(plan_step "$lv" "tracker tasks" '{"status":"done","summary":"x"}' "Live child")"
printf '4242\t%s\tclaude\n' "$wv" > "$FLOW_HEALTH_PROCS"
"$P/scripts/advance.sh" "$lv" >/dev/null 2>&1
check "split: a worktree a live session works in is kept" sh -c "[ -f '$wv/.flow/claim.json' ] && grep -q '	$lv	split	.*is kept: a session works in it' .flow/events.log"
: > "$FLOW_HEALTH_PROCS"; "$P/scripts/steward.sh" health >/dev/null 2>&1
check "health: once the session is gone the split is released" [ ! -f "$wv/.flow/claim.json" ]
# A parent split before 1.19.0: step plan, the gate long cleared, still claimed.
op="$("$P/scripts/new.sh" task "Old split" --size M --body x)"
wo="$(plan_step "$op" "tracker tasks" '{"status":"done"}' "Old child")"
rm -f .flow/runs/local-task-*.json
"$P/adapters/local/write-state.sh" "$op" step=plan gate=none answered=decomposition
"$P/scripts/steward.sh" health > "$work/split.out" 2>&1
check "health: a parent split before 1.19.0 is finished: step split, worktree released" sh -c "[ ! -f '$wo/.flow/claim.json' ] && [ \"\$('$P/adapters/local/read.sh' '$op' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"state\"][\"step\"])')\" = split ]"
# An item at implement with the decomposition answer left over and a follow-up child: untouched.
fp="$("$P/scripts/new.sh" task "Has a follow-up" --size M --body x)"
wf="$(plan_step "$fp" "tracker tasks" '{"status":"done"}')"
rm -f .flow/runs/local-task-*.json
"$P/adapters/local/write-state.sh" "$fp" step=implement answered=decomposition
"$P/scripts/new.sh" task "Follow-up" --size S --parent "$fp" --body x >/dev/null 2>&1
"$P/scripts/steward.sh" health > "$work/split.out" 2>&1
check "health: an item at implement with a follow-up child is not split" sh -c "[ -f '$wf/.flow/claim.json' ] && [ \"\$('$P/adapters/local/read.sh' '$fp' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"state\"][\"step\"])')\" = implement ]"
# The implement step finds open children in tracker-tasks mode: it splits, and advance keeps it split.
"$P/scripts/next.sh" "$fp" >/dev/null 2>&1
"$P/scripts/steward.sh" split "$fp" > "$work/split.out" 2>&1
check "split: during a run the worktree stays" sh -c "[ -f '$wf/.flow/claim.json' ] && grep -q 'is kept: a run is in flight' '$work/split.out'"
"$P/scripts/advance.sh" "$fp" --status done --summary "the children are open" >/dev/null 2>&1; code=$?
check "split: the implement step's result does not move a split item, and the run's end releases it" sh -c "[ $code -eq 4 ] && [ ! -f '$wf/.flow/claim.json' ] && [ \"\$('$P/adapters/local/read.sh' '$fp' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"state\"][\"step\"])')\" = split ]"
# Under a gate: uncommitted changes, and threads awaiting a reply at the merge gate, are said once.
mg="$("$P/scripts/new.sh" task "At the merge gate" --size S --body x)"; wm="$("$P/scripts/steward.sh" claim "$mg")"
"$P/adapters/local/write-state.sh" "$mg" step=pr gate=merge pr=https://gh/pull/90
printf 'half a fix\n' > "$wm/half.txt"
python3 - "$FAKE_GH_DIR/issues.json" <<'PY4'
import json, sys
d = json.load(open(sys.argv[1])); d["pr"] = d.get("pr") or {}; d["pr"].update(number=90, state="OPEN", updatedAt="2026-10-25T00:00:00Z", headRefOid="abc", mergeable="MERGEABLE")
d["threads"] = [{"id": "T_7", "isResolved": False, "isOutdated": False, "path": "src/RodAgent.cs", "line": 3,
                 "comments": {"nodes": [{"databaseId": 701, "body": "The carry walk drops the ball.", "author": {"login": "chatgpt-codex-connector"}, "createdAt": "t"}]}}]
json.dump(d, open(sys.argv[1], "w"))
PY4
"$P/scripts/steward.sh" health > "$work/split.out" 2>&1; "$P/scripts/steward.sh" health >> "$work/split.out" 2>&1
check "health: a gated item with uncommitted changes is said once, the changes untouched" sh -c "[ \"\$(grep -c '$mg: waits at the merge gate with uncommitted changes in app-wt-' '$work/split.out')\" = 1 ] && [ -f '$wm/half.txt' ]"
check "health: threads awaiting a reply at the merge gate are said once" sh -c "[ \"\$(grep -c '$mg: PR #90 has 1 unresolved review thread(s) awaiting a reply while $mg waits at the merge gate' '$work/split.out')\" = 1 ]"
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['threads']=[]; json.dump(d, open(p,'w'))"
# A worktree left dirty by a pass cut off before 1.19.0 (no note): the next pass is told to continue.
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr'].update(headRefName='flow/gh-77', updatedAt='2026-10-25T01:00:00Z'); json.dump(d, open(p,'w'))"
mkdir -p "$wm/.flow/reports" && printf '{"item":"gh#77","branch":"flow/gh-77","base":"main"}\n' > "$wm/.flow/claim.json"
printf '#!/bin/sh\nprintf "%%s\\t%%s\\t%%s\\n" "$0" "$PWD" "$*" >> "%s/host77.log"\n' "$work" > "$work/bin/claude"; chmod +x "$work/bin/claude"
"$P/jobs/comments.sh" claude 90 >/dev/null 2>&1
check "comments job: uncommitted changes with no note get one, and the pass is told to read it" sh -c "grep -q '90: .*holds uncommitted changes from an earlier run' .flow/log/comments.log && grep -q 'An earlier pass was cut short: read .*gh-77/comments-resume.md first' '$work/host77.log' && [ -f '$wm/.flow/reports/gh-77/comments-resume.md' ]"
check "comments job: a pass that completes with the tree still dirty keeps the note" [ -f "$wm/.flow/reports/gh-77/comments-resume.md" ]
rm "$wm/half.txt"; "$P/jobs/comments.sh" claude 90 >/dev/null 2>&1
check "comments job: a pass that completes with a clean tree removes the note" [ ! -f "$wm/.flow/reports/gh-77/comments-resume.md" ]
# P2-7: a reports folder in a worktree another item holds gets no dirty-tree note.
python3 -c "import json; p='$FAKE_GH_DIR/issues.json'; d=json.load(open(p)); d['pr'].update(headRefName='flow/gh-78', updatedAt='2026-10-25T02:00:00Z'); json.dump(d, open(p,'w'))"
mkdir -p "$wm/.flow/reports/gh-78" && printf 'other work\n' > "$wm/other.txt"
"$P/jobs/comments.sh" claude 90 >/dev/null 2>&1
check "comments job: no dirty-tree note when the worktree's claim names another item" sh -c "[ ! -f '$wm/.flow/reports/gh-78/comments-resume.md' ] && ! grep -q 'gh-78/comments-resume.md' '$work/host77.log'"
rm -f "$wm/other.txt"
git init -q --bare "$work/split-origin.git" && git remote add origin "$work/split-origin.git" && git push -q origin main 2>/dev/null
up="$("$P/scripts/new.sh" task "Pushed branch" --size S --body x)"; wu="$("$P/scripts/steward.sh" claim "$up")"; bu="$(git -C "$wu" symbolic-ref --short HEAD)"
printf 'x\n' > "$wu/x.txt" && git -C "$wu" add x.txt && git -C "$wu" commit -qm x && git -C "$wu" push -q -u origin "$bu" 2>/dev/null
"$P/scripts/steward.sh" release "$up" > /dev/null 2> "$work/split.err"
check "release: a branch merged into its upstream but ahead of the base is kept" sh -c "git show-ref --verify --quiet 'refs/heads/$bu' && grep -q 'is not merged into origin/main; kept' '$work/split.err'"
check "new: an unreadable parent is warned about, and the child is still made" sh -c "'$P/scripts/new.sh' task 'Orphan' --size S --parent local:task/999 --body x 2>'$work/split.err' | grep -q '^local:task/' && grep -q 'cannot read the parent local:task/999' '$work/split.err'"
unset FLOW_HEALTH_PROCS

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
check "gate json: each gate has the fields the console reads" [ "$(printf '%s' "$gj" | python3 -c 'import json,sys; print(",".join(json.load(sys.stdin)[2]))')" = "item,gate,message,time,host,worktree,age_seconds,questions" ]
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
"$P/scripts/gate.sh" raise "$d1" escalation 007 >/dev/null 2>&1
check "a gate raised with the message 007: the record parses, the message the string" [ "$(jtype message < ".flow/gates/$(item_slug "$d1").json")" = "str 007" ]
check "gate list --json: the message 007 is the string" [ "$("$P/scripts/gate.sh" list --json | jtype 0.message)" = "str 007" ]
"$P/scripts/lesson.sh" other "$d1" 12345 >/dev/null
check "a lesson whose text is 12345 is the string" [ "$(tail -1 .flow/lessons.jsonl | jtype text)" = "str 12345" ]
check_all "runs.jsonl: seconds and exit are numbers on every line, result a string" '[ -s "$home2/log/runs.jsonl" ] && python3 -c "import json,sys
for l in open(sys.argv[1]):
    r = json.loads(l); assert type(r[\"seconds\"]) is int and type(r[\"exit\"]) is int and type(r[\"result\"]) is str, l" "$home2/log/runs.jsonl"'

[ "$fails" -eq 0 ] && { echo "flow: ok"; exit 0; }
echo "flow: $fails failed"; exit 1
