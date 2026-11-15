# _verify_fixture.sh: the fixture verify-detached.sh and verify-ends.sh source, on top of
# _base_fixture.sh: an item claimed in a fresh repo with its gates (new_item), the run's record and
# report readers, held gates, stand-in runs (fake_run) and the polls that wait on a run. Sourced
# after _base_fixture.sh, never run.
verify() { (cd "$worktree" && "$plugin/scripts/verify.sh" "$item" "$@"); }
failed_checks() { python3 -c 'import json,sys; print(",".join(check["name"] for check in json.load(open(sys.argv[1]))["checks"] if check["status"]=="fail"))' "$reports/verify.json"; }
report_status() { json_value status < "$reports/verify.json"; }
# run_pid: the pid the run's record names (lib/verify.sh: one `key value` line each).
run_pid() { sed -n 's/^pid //p' "$reports/verify.run" | head -n 1; }
# process_running <pid>: lib/verify.sh's own test of a live process.
. "$plugin/lib/verify.sh"
# until_true <seconds> '<condition>': polls the condition until it holds or the seconds pass.
until_true() { until_deadline=$(( $(date +%s) + $1 )); until (eval "$2") >/dev/null 2>&1; do [ "$(date +%s)" -lt "$until_deadline" ] || return 1; sleep 0.2; done; }
# wait_until_ended: --wait called again and again, as the verifier does, until it stops saying 3;
# 124 when it still says 3 after 24 calls (about 2 minutes), so a run that never ends fails the
# check instead of hanging the suite.
wait_until_ended() {
  wait_calls=0
  while [ "$wait_calls" -lt 24 ]; do verify --wait 5 >/dev/null 2>&1; wait_code=$?; [ "$wait_code" -eq 3 ] || return "$wait_code"; wait_calls=$((wait_calls + 1)); done
  return 124
}

# fake_run <name> [ignore-term]: a process in its own session and the item's worktree (or in
# run_cwd when set) whose command line reads `verify.sh <item> --detached`, as a detached run's
# does, that waits for release-<name> or for the test's folder to go; with ignore-term it ignores
# TERM. Prints its pid.
fake_run() {
  mkdir -p "$work/fake-$1"
  { [ "${2:-}" != ignore-term ] || echo "trap '' TERM"
    echo "while [ ! -f $work/release-$1 ] && [ -d $work ]; do sleep 0.2; done"; } > "$work/fake-$1/verify.sh"
  python3 -c 'import subprocess,sys; print(subprocess.Popen(["sh"] + sys.argv[2:], cwd=sys.argv[1], start_new_session=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).pid)' "${run_cwd:-$worktree}" "$work/fake-$1/verify.sh" "$item" --detached
}
# write_run_record <reports> <pid> [started] [limit]: a verify.run in lib/verify.sh's format.
write_run_record() {
  printf 'pid %s\nstarted %s\nhead %s\nlimit %s\n' "$2" "${3:-$(date +%s)}" "$(git -C "$worktree" rev-parse --short HEAD)" "${4:-7200}" > "$1/verify.run"
}

# new_item <dir> <gates yaml>: a fresh repo with the gates, a claimed item with one committed
# change; sets worktree, item and reports.
new_item() {
  root="$work/$1"; mkdir -p "$root" && cd "$root" || exit 1
  git init -q app && cd app && git config user.email t@t && git config user.name t && git symbolic-ref HEAD refs/heads/main
  printf 'hi\n' > README.md && git add -A && git commit -qm init
  for worktree_number in 1 2; do git worktree add -q -b "main-wt-$worktree_number" "../wt-$worktree_number"; done
  mkdir -p .flow
  printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\npool_max: 2\nnotify:\n  desktop: false\n%sgates:\n%s\n' "${limit_yaml:-}" "$2" > .flow/config.yaml
  item="$("$local_adapter/create.sh" task "Detached $1" --size S --body x)"
  "$plugin/scripts/next.sh" "$item" >/dev/null 2>&1
  worktree="$("$plugin/scripts/steward.sh" find "$item")"
  printf 'x\n' > "$worktree/change.txt" && git -C "$worktree" add -A && git -C "$worktree" commit -qm change
  reports="$worktree/.flow/reports/$(slug "$item")"; mkdir -p "$reports"
}
# record_a_dead_agent: the item's run record names a pid that is gone and started two days ago, as
# one whose agent ended while its verify goes on; stop and health then act on nothing else.
record_a_dead_agent() { python3 -c 'import json,sys,time; path=sys.argv[1]; record=json.load(open(path)); record["pid"]=999999; record["started"]=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time()-172800)); json.dump(record, open(path,"w"))' ".flow/runs/$(slug "$item").json"; }
# held_gate <name>: a gate that counts its runs in <name>.count and ends once release-<name>
# exists or the test's folder is gone, failing when fail-<name> exists. Health counts any detached
# run of the item id as live, so a gate left waiting would hold a later test run's health checks.
held_gate() { printf "  %s: 'sh -c \"echo run >> %s/%s.count; while [ ! -f %s/release-%s ] && [ -d %s ]; do sleep 0.2; done; [ ! -f %s/fail-%s ]\"'\n" "$1" "$work" "$1" "$work" "$1" "$work" "$work" "$1"; }
