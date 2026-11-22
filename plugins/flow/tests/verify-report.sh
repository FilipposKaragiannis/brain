#!/bin/sh
# verify-report.sh: the verify runner: its checks and gates, a report that is never empty, gate paths and
# the mutation switch.
# Takes no argument. Exit 0 when every check passes, 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$P"
work="$(mktemp -d)"
. "$P/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$P"
trap 'sandbox_close $?' EXIT
. "$here/_flow_setup.sh"
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
osc="$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import _verify_report as v
print(v.summary("cut short at \x1b]8;;https://ci/run/7"))' "$P/scripts" 2>&1)"
check "a hyperlink cut short with no terminator leaves no target in the summary" [ "$osc" = "cut short at" ]
# dash runs no EXIT trap on a signal: a verify stopped by TERM must still remove its temp files.
if command -v dash >/dev/null 2>&1; then
  verify_temporary_file_exists() {
    for candidate in "$1"/flow-verify.*; do [ ! -f "$candidate" ] || return 0; done
    return 1
  }
  hold_polls=100; hold_poll_seconds=0.1
  mkdir -p "$work/vtmp"
  printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\ngates:\n  slow: sleep 2\nnotify:\n  desktop: false\n' > .flow/config.yaml
  (cd "$wv" && TMPDIR="$work/vtmp" exec dash "$P/scripts/verify.sh" "$v1" >/dev/null 2>&1) & vp=$!
  n=0; while ! verify_temporary_file_exists "$work/vtmp" && [ "$n" -lt "$hold_polls" ]; do n=$((n + 1)); sleep "$hold_poll_seconds"; done
  kill -TERM "$vp" 2>/dev/null; wait "$vp"
  check_all "VerifyStoppedBySignal_RemovesItsTemporaryFiles because its scratch records are private to the run" '[ "$n" -lt "$hold_polls" ] && ! verify_temporary_file_exists "$work/vtmp"'
  mkdir -p "$work/vtmp-held" "$work/held-mktemp"; rm -f "$work/held-mktemp.go"
  printf '#!/bin/sh\nmade="$(%s "$@")" || exit 1\nprintf "%%s\\n" "$made"\ncase "$made" in "$TMPDIR"/*) n=0; while [ ! -f %s/held-mktemp.go ] && [ "$n" -lt %s ]; do sleep %s; n=$((n + 1)); done ;; esac\n' \
    "$(command -v mktemp)" "$work" "$hold_polls" "$hold_poll_seconds" > "$work/held-mktemp/mktemp"; chmod +x "$work/held-mktemp/mktemp"
  (cd "$wv" && PATH="$work/held-mktemp:$PATH" TMPDIR="$work/vtmp-held" exec dash "$P/scripts/verify.sh" "$v1" >/dev/null 2>&1) & vp=$!
  n=0; while ! verify_temporary_file_exists "$work/vtmp-held" && [ "$n" -lt "$hold_polls" ]; do n=$((n + 1)); sleep "$hold_poll_seconds"; done
  kill -TERM "$vp" 2>/dev/null; touch "$work/held-mktemp.go"; wait "$vp"
  check_all "TermWhileVerifyMakesItsFirstTempFile_LeavesNoTempFile because cleanup also owns the first allocation" '[ "$n" -lt "$hold_polls" ] && ! verify_temporary_file_exists "$work/vtmp-held"'
fi
# The write is atomic: a reader polling verify.json while verify runs never sees it empty, and
# no temp file is left behind.
: > "$work/reads.bad"
(for _ in 1 2 3; do (cd "$wv" && "$P/scripts/verify.sh" "$v1" >/dev/null 2>&1); done; : > "$work/verify.done") &
vpid=$!
reader_interval_seconds=0.01
while [ ! -f "$work/verify.done" ] && kill -0 "$vpid" 2>/dev/null; do
  [ -e "$rv/verify.json" ] && [ ! -s "$rv/verify.json" ] && echo empty >> "$work/reads.bad"
  sleep "$reader_interval_seconds"
done
wait "$vpid"
check "VerifyWriterExits_CompletesAllWrites because the reader needs a completed observation window" test -f "$work/verify.done"
rm -f "$work/verify.done"
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

[ "$fails" -eq 0 ] && { echo "verify-report: ok"; exit 0; }
echo "verify-report: $fails failed"; exit 1
