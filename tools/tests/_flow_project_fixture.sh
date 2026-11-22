project="$work/marketplace"
suite="$project/plugins/flow/tests"
mkdir -p "$project/tools/lib" "$project/.standards" "$suite"
cp "$tools/lib/flow_suites.py" "$tools/lib/flow_selection.py" "$tools/lib/flow_process_groups.py" "$project/tools/lib/"
cp "$tools/test.sh" "$project/tools/"
cp "$tools/../.standards/config.json" "$project/.standards/"
cd "$project"
git init -q -b main
git config user.email tests@example.test
git config user.name Tests
printf 'echo "  ok   StubCheck_Holds"\n' > "$suite/sessions.sh"
printf 'exit 1\n' > "$suite/run.sh"
for name in base-claim base-readers verify-scope verify-report; do printf 'exit 0\n' > "$suite/$name.sh"; done
printf 'test "$1" != jira\n' > "$suite/adapter-contract.sh"
git add .
git commit -qm baseline
base="$(git rev-parse HEAD)"

result() { if "$project/tools/test.sh" flow-since "$base" > "$work/output" 2>&1; then echo pass; else echo fail; fi; }
expect() { [ "$2" = "$3" ] || { echo "FAIL $1"; cat "$work/output"; exit 1; }; echo "ok $1"; }
suites_reported() { grep -cE '^flow: [^ ]+ (pass|FAIL) \(' "$work/output"; }
poll_seconds=0.1; wait_ticks=50
process_probe="$work/process-running.sh"
printf '%s\n' 'case "$(ps -o stat= -p "$1" 2>/dev/null | tr -d " ")" in ""|Z*) exit 1 ;; esac' > "$process_probe"
process_running() { sh "$process_probe" "$1"; }
process_state() {
  ticks=0; while process_running "$1" && [ "$ticks" -lt "$wait_ticks" ]; do sleep "$poll_seconds"; ticks=$((ticks + 1)); done
  if process_running "$1"; then kill -KILL "$1"; echo running; else echo ended; fi
}
