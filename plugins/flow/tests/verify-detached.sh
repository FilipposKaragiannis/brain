#!/bin/sh
# verify-detached.sh: a verify run started with verify.sh <item> --start runs detached and is
# waited on with --wait, on the local adapter in throwaway repos. --start returns while the checks
# run and clears the earlier report; a second --start while one runs starts nothing; --wait exits
# 0 on pass, 1 on fail (a gate that failed, a run past verify.limit, a run killed with no report),
# 3 while it runs and 2 with no run; verify.limit stops the gate's whole process group; steward
# stop and release end the run, and health does not take an item whose verify runs for dead.
# Each gate waits for a file the test creates, so the test decides when a check ends.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
plugin="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$plugin"
work="$(mktemp -d)"
# On exit every held gate is let go, so no detached run outlives the test.
trap 'for gate_name in started unstarted killed stopped released health; do touch "$work/release-$gate_name"; done; [ -n "${KEEP:-}" ] || rm -rf "$work"' EXIT
unset FLOW_SLACK_WEBHOOK FLOW_HOME
mkdir -p "$work/home" "$work/offline" && HOME="$work/home" && export HOME && unset CODEX_HOME
for tool in curl wget gh osascript notify-send claude codex launchctl; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/offline.log"\n' "$tool" "$work" > "$work/offline/$tool"
  chmod +x "$work/offline/$tool"
done
PATH="$work/offline:$PATH"; export PATH
export FLOW_HEALTH_PROCS="$work/procs"; : > "$FLOW_HEALTH_PROCS"
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { # check <name> '<condition>': the condition is shell text, run whole; a FAIL shows its output
  if said="$( (eval "$2") 2>&1)"; then pass "$1"; else fail "$1"; [ -z "$said" ] || printf '%s\n' "$said" | sed 's/^/       /'; fi
}
json_value() { python3 -c 'import json,sys; value=json.load(sys.stdin)
for key in sys.argv[1].split("."): value = value[int(key)] if key.isdigit() else value[key]
print(value if isinstance(value,str) else json.dumps(value))' "$1"; }
local_adapter="$plugin/adapters/local"
slug() { printf '%s' "$1" | tr ':/#' '---'; }
verify() { (cd "$worktree" && "$plugin/scripts/verify.sh" "$item" "$@"); }
failed_checks() { python3 -c 'import json,sys; print(",".join(check["name"] for check in json.load(open(sys.argv[1]))["checks"] if check["status"]=="fail"))' "$reports/verify.json"; }
report_status() { json_value status < "$reports/verify.json"; }
# run_pid: the pid the run's record names (lib/verify.sh: one `key value` line each).
run_pid() { sed -n 's/^pid //p' "$reports/verify.run" | head -n 1; }
process_running() { case "$(ps -o stat= -p "$1" 2>/dev/null | tr -d ' ')" in ''|Z*) return 1 ;; esac; }
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

echo "verify --start returns while the checks run, and --wait follows the run"
new_item started "$(held_gate started)"
printf '{"status":"pass","checks":[]}\n' > "$reports/verify.json"; printf 'earlier\n' > "$reports/verify.md"
# --start runs in the background: one that waited for its gate would never end, as the gate is
# held, so the check fails on the time instead of hanging the suite.
(verify --start >/dev/null 2>&1; echo "$?" > "$work/start.code") &
check "StartWithAGateStillRunning_ReturnsAtOnce: --start detaches the checks instead of waiting for them" \
  'until_true 30 "[ -s $work/start.code ]"'
check "StartWithAGateStillRunning_ExitsZero: a started run is no failure" '[ "$(cat "$work/start.code")" = 0 ]'
check "StartAfterAnEarlierRun_RemovesTheEarlierVerifyJson: no report of an earlier run may read as this one's" \
  '[ ! -f "$reports/verify.json" ]'
check "StartAfterAnEarlierRun_RemovesTheEarlierVerifyMd: the PR body never embeds an earlier run's twin" \
  '[ ! -f "$reports/verify.md" ]'
until_true 20 '[ -s "$work/started.count" ]'
verify --wait 1 >/dev/null 2>&1; running_code=$?
check "WaitWhileTheGateRuns_ExitsThree: 3 tells the verifier to call --wait again" '[ "$running_code" -eq 3 ]'
verify --start >/dev/null 2>&1
touch "$work/release-started"
wait_until_ended; ended_code=$?
check "SecondStartWhileARunGoes_StartsNothing: the checks run once, in the run already going" \
  '[ "$(wc -l < "$work/started.count" | tr -d " ")" = 1 ]'
check "WaitAfterAPassingRun_ExitsZero: 0 is a pass" '[ "$ended_code" -eq 0 ]'
check "WaitAfterAPassingRun_ReportSaysPass: the report the run wrote is the step result" '[ "$(report_status)" = pass ]'

echo "verify --wait after a failing gate"
new_item failing "$(held_gate failing)"
touch "$work/fail-failing" "$work/release-failing"
verify --start >/dev/null 2>&1
wait_until_ended; ended_code=$?
check "WaitAfterAFailingGate_ExitsOne: 1 is a fail" '[ "$ended_code" -eq 1 ]'
check "WaitAfterAFailingGate_ReportSaysFail: the failed gate fails the run" '[ "$(report_status)" = fail ]'

echo "verify --wait with no run started"
new_item unstarted "$(held_gate unstarted)"
verify --wait 1 >/dev/null 2>&1; unstarted_code=$?
check "WaitWithNoRunStarted_ExitsTwo: there is nothing to wait for" '[ "$unstarted_code" -eq 2 ]'

echo "a run killed with no report"
new_item killed "$(held_gate killed)"
verify --start >/dev/null 2>&1
until_true 20 '[ -s "$work/killed.count" ]'
killed_pid="$(run_pid)"
check "KilledRun_RecordNamesALiveProcess: the record must name the run, or the kill below proves nothing" \
  'process_running "$killed_pid"'
kill -9 -"$killed_pid" 2>/dev/null || kill -9 "$killed_pid"
until_true 20 '! process_running "$killed_pid"'
wait_until_ended; ended_code=$?
check "WaitAfterTheRunWasKilled_ExitsOne: a run that died with no report is a fail" '[ "$ended_code" -eq 1 ]'
check "WaitAfterTheRunWasKilled_ReportSaysFail: the verifier still has a report to read" '[ "$(report_status)" = fail ]'

echo "verify.limit stops a run that takes longer"
limit_yaml="verify:
  limit: 5s
"
# The gate never ends on its own: its child waits for the test's folder to go.
new_item limited "  slow: 'sh -c \"sh -c \\\"while [ -d $work ]; do sleep 1; done\\\" & echo \\\$! > $work/slow-child.pid; wait\"'"
limit_yaml=""
verify --start >/dev/null 2>&1
until_true 20 '[ -s "$work/slow-child.pid" ]'
slow_child="$(cat "$work/slow-child.pid")"
check "LimitedRun_GateChildRunsBeforeTheLimit: the child must run, or its end below proves nothing" \
  'process_running "$slow_child"'
wait_until_ended; ended_code=$?
check "RunPastTheLimit_WaitExitsOne: a run stopped at verify.limit is a fail" '[ "$ended_code" -eq 1 ]'
check "RunPastTheLimit_ReportNamesTheCheckThatRan: the owner learns which gate is slow" \
  '[ "$(failed_checks)" = "gate slow" ]'
check "RunPastTheLimit_GateChildIsStopped: the whole process group stops, not only the run" \
  'until_true 20 "! process_running $slow_child"'

echo "steward stop and release end the detached run"
new_item stopped "$(held_gate stopped)"
record_a_dead_agent
verify --start >/dev/null 2>&1
until_true 20 '[ -s "$work/stopped.count" ]'
stopped_pid="$(run_pid)"
check "StoppedRun_RecordNamesALiveProcess: the record must name the run, or its end below proves nothing" \
  'process_running "$stopped_pid"'
"$plugin/scripts/steward.sh" stop "$item" >/dev/null 2>&1
check "StewardStopOnAnItemWithADetachedVerify_EndsTheVerifyRun: a stopped item runs nothing" \
  'until_true 30 "! process_running $stopped_pid"'

new_item released "$(held_gate released)"
verify --start >/dev/null 2>&1
until_true 20 '[ -s "$work/released.count" ]'
released_pid="$(run_pid)"
check "ReleasedRun_RecordNamesALiveProcess: the record must name the run, or its end below proves nothing" \
  'process_running "$released_pid"'
rm -f ".flow/runs/$(slug "$item").json"
"$plugin/scripts/steward.sh" release "$item" --force >/dev/null 2>&1
check "StewardReleaseOfAnItemWithADetachedVerify_EndsTheVerifyRun: a released worktree is not checked on" \
  'until_true 30 "! process_running $released_pid"'

echo "health counts a detached verify run as the item's live run"
new_item health "$(held_gate health)"
printf 'jobs:\n  health:\n    grace: 1s\n' >> .flow/config.yaml
record_a_dead_agent
verify --start >/dev/null 2>&1
until_true 20 '[ -s "$work/health.count" ]'
sleep 3
env -u FLOW_HEALTH_PROCS "$plugin/scripts/steward.sh" health --dry-run > "$work/health-live.out" 2>&1
check "HealthWhileTheDetachedVerifyRuns_DoesNotTakeTheRunForDead: the verify run is the item's live run" \
  '! grep -q "$item.*dead run" "$work/health-live.out"'
touch "$work/release-health"
wait_until_ended
sleep 3
env -u FLOW_HEALTH_PROCS "$plugin/scripts/steward.sh" health --dry-run > "$work/health-ended.out" 2>&1
cat "$work/health-ended.out" >&2; ps -axww -o pid=,command= | grep "verify.sh" | grep -v grep >&2; cat "$reports/verify.json" >&2
check "HealthAfterTheDetachedVerifyEnded_TakesTheRunForDead: the record is the same, so only the verify run kept it alive" \
  'grep -q "$item.*dead run" "$work/health-ended.out"'

if [ "$fails" -eq 0 ]; then echo "verify-detached: ok"; else echo "verify-detached: $fails failed"; exit 1; fi
