#!/bin/sh
# The console demo: a throwaway flow project and a trial console on it alone, so the console is
# tested without touching a real project. Re-running it stops that console and the runs it started
# and builds the demo again.
#   demo.sh [--dir <folder>] [--port <n>]
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
console="$(cd "$here/.." && pwd)"
DEMO_PORT=7478
REAL_CONSOLE_PORT=7474
MARKER=.brain-console-demo
# What launchctl print exits with for a job it does not have.
LAUNCHCTL_NOT_LOADED=113
USAGE_EXIT=2
# How long a run the demo's console started gets after SIGTERM, then after SIGKILL: 20 polls of
# half a second, the daemon's own 10 seconds of grace.
RUN_STOP_POLLS=20
RUN_STOP_POLL_SECONDS=0.5

die() { echo "demo: $1" >&2; exit "${2:-1}"; }
usage() { die "usage: demo.sh [--dir <folder>] [--port <n>]" "$USAGE_EXIT"; }

temporary="${TMPDIR:-/tmp}"
demo_dir="${temporary%/}/brain-console-demo"
port="$DEMO_PORT"
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) [ $# -ge 2 ] || usage; demo_dir="$2"; shift 2 ;;
    --port) [ $# -ge 2 ] || usage; port="$2"; shift 2 ;;
    *) usage ;;
  esac
done
case "$port" in ''|*[!0-9]*) die "--port takes a number, not '$port'" "$USAGE_EXIT" ;; esac
[ "$port" -ne "$REAL_CONSOLE_PORT" ] || die "port $REAL_CONSOLE_PORT is the real console's; give the demo another" "$USAGE_EXIT"
case "$demo_dir" in /*) ;; *) demo_dir="$(pwd)/$demo_dir" ;; esac
flow="$console/../flow"
[ -f "$flow/scripts/gate.sh" ] || flow="${FLOW_PLUGIN:-}"
[ -n "$flow" ] && [ -f "$flow/scripts/gate.sh" ] || die "no flow plugin beside this console and none in FLOW_PLUGIN; set FLOW_PLUGIN to one" "$USAGE_EXIT"
flow="$(cd "$flow" && pwd)"

home="$demo_dir/home"
stubs="$demo_dir/bin"
project="$demo_dir/console-demo"
state="$demo_dir/state"
config="$demo_dir/config.json"
daemon="$console/app/daemon/src/main.ts"

# demo_env <command...>: the command with the demo's environment and nothing else.
demo_env() {
  env -i HOME="$home" PATH="$stubs:$PATH" TMPDIR="$temporary" LANG=C USER="${USER:-demo}" SHELL="${SHELL:-/bin/sh}" \
    FLOW_PLUGIN="$flow" BRAIN_CONSOLE_LAUNCHCTL="$stubs/launchctl" "$@"
}
in_project() { (cd "$project" && demo_env "$@"); }

is_empty_dir() { [ -d "$1" ] && [ -z "$(ls -A "$1")" ]; }
refuse_foreign_dir() {
  [ -f "$demo_dir/$MARKER" ] || die "$demo_dir is not a demo this script built (it has no $MARKER), so it stays; give another --dir" "$USAGE_EXIT"
}
stop_demo_daemon() {
  # Only with the stub launchctl: the real one would find the owner's console and stop that.
  [ -f "$state/daemon.pid" ] && [ -x "$stubs/launchctl" ] || return 0
  (cd "$demo_dir" && demo_env node "$daemon" stop --state-dir "$state" --config "$config") || true
}
# cwd_of <pid>: the folder the process runs in, or nothing when it cannot be read.
cwd_of() {
  if [ -d /proc ]; then readlink "/proc/$1/cwd" 2>/dev/null && return 0; fi
  command -v lsof > /dev/null 2>&1 && lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'
}
# demo_run_pids: the detached runs the demo's console started that still run. Each flow job writes
# its pid to a lock in the demo's .flow/log and leads its own process group (the daemon or the job
# spawns it so). A pid counts only while it runs a flow job script, leads its group and works in
# the demo folder, so a stale lock naming a pid since reused never reaches another process.
demo_run_pids() {
  real="$(cd "$demo_dir" && pwd -P)"
  for lock in "$project"/.flow/log/*.lock/pid; do
    [ -f "$lock" ] || continue
    pid="$(cat "$lock" 2>/dev/null)"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    case "$(ps -o command= -p "$pid" 2>/dev/null)" in *jobs/*.sh*) ;; *) continue ;; esac
    [ "$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')" = "$pid" ] || continue
    case "$(cwd_of "$pid")/" in "$real"/*) echo "$pid" ;; esac
  done
}
group_alive() { for g in "$@"; do kill -0 -- "-$g" 2>/dev/null && return 0; done; return 1; }
# wait_groups <group...>: waits, a bounded while, for every process in the groups to end.
wait_groups() {
  waited=0
  while group_alive "$@" && [ "$waited" -lt "$RUN_STOP_POLLS" ]; do sleep "$RUN_STOP_POLL_SECONDS"; waited=$((waited + 1)); done
}
# stop_demo_runs: the daemon leaves detached runs going by design, so a run the demo's console
# started would work on the folder about to be deleted and on the items rebuilt with its ids.
# Ends each run's whole group, as the daemon's stop does: SIGTERM, then SIGKILL after the grace.
stop_demo_runs() {
  runs="$(demo_run_pids)"
  [ -n "$runs" ] || return 0
  # $runs splits on purpose: one pid a line.
  for g in $runs; do kill -s TERM -- "-$g" 2>/dev/null || true; done
  wait_groups $runs
  group_alive $runs || return 0
  for g in $runs; do kill -s KILL -- "-$g" 2>/dev/null || true; done
  wait_groups $runs
  ! group_alive $runs || die "a run the demo's console started outlived SIGKILL (process groups $(echo $runs)), so the demo stays; stop it and run this again"
}
# reset_demo: stops the demo's daemon and its runs, then deletes the folder, only when this script built it.
reset_demo() {
  [ -e "$demo_dir" ] || return 0
  is_empty_dir "$demo_dir" && return 0
  refuse_foreign_dir
  stop_demo_daemon
  stop_demo_runs
  rm -rf "$demo_dir"
}

# write_agent_stub <tool> < <reply>: a <tool> that logs each call to the demo's agents.log and
# prints <reply>, the JSON the real CLI would print, with no session started and no tokens spent.
write_agent_stub() {
  {
    cat <<'STUB'
#!/bin/sh
# An agent CLI in the console demo: logs the call and answers with no agent run and no tokens spent.
printf '%s\t%s\t%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PWD" "$(basename "$0")" "$(printf '%s' "$*" | tr '\n' ' ')" >> "$(dirname "$0")/../agents.log"
cat <<'REPLY'
STUB
    cat
    echo REPLY
  } > "$stubs/$1"
}
# write_refusing_stub <tool>: a <tool> that refuses, so the demo never reaches GitHub, the crontab or launchd.
write_refusing_stub() {
  {
    printf '#!/bin/sh\n# %s in the console demo: refuses, so the demo never reaches GitHub, the crontab or launchd.\n' "$1"
    printf 'echo "%s: a stand-in in the console demo; nothing was read or changed" >&2\n' "$1"
    if [ "$1" = launchctl ]; then printf '[ "$1" = print ] && exit %s\n' "$LAUNCHCTL_NOT_LOADED"; fi
    printf 'exit 1\n'
  } > "$stubs/$1"
}
write_stubs() {
  mkdir -p "$stubs"
  write_agent_stub claude <<'JSON'
{"type":"result","subtype":"success","is_error":false,"result":"The demo stub answered: no agent ran and no tokens were spent.","usage":{"input_tokens":0,"output_tokens":0},"total_cost_usd":0}
JSON
  write_agent_stub codex <<'JSON'
{"type":"item.completed","item":{"type":"agent_message","text":"The demo stub answered: no agent ran and no tokens were spent."}}
{"type":"turn.completed","usage":{"input_tokens":0,"output_tokens":0}}
JSON
  for tool in gh crontab launchctl; do write_refusing_stub "$tool"; done
  chmod +x "$stubs"/*
}

# build_project: the repo, flow installed by its own init, and the two pool worktrees.
build_project() {
  mkdir -p "$home" "$project/.flow"
  printf '[user]\n\tname = Console Demo\n\temail = demo@example.com\n' > "$home/.gitconfig"
  in_project git init -q -b main
  printf '# Console demo\n\nA throwaway flow project that plugins/console/scripts/demo.sh builds to test the console on.\nRe-running the script deletes it.\n' > "$project/README.md"
  in_project git add README.md
  in_project git commit -q -m "chore: the console demo"
  printf 'adapters:\n  default: local\nbase: main\nnotify:\n  desktop: false\n' > "$project/.flow/config.yaml"
  in_project sh "$flow/skills/init/scripts/init.sh" > /dev/null
  in_project "$flow/scripts/steward.sh" add ../console-demo-wt-1 > /dev/null
  in_project "$flow/scripts/steward.sh" add ../console-demo-wt-2 > /dev/null
}

# new_item <kind> <size> <title> <step>: a local item at that step (none: ready); prints its id.
new_item() (
  created="$(in_project "$flow/adapters/local/create.sh" "$1" "$3" --size "$2" --body "A demo item for testing the console.

## Acceptance
- [ ] The console shows it")"
  [ "$4" = none ] || in_project "$flow/adapters/local/write-state.sh" "$created" "step=$4" > /dev/null
  printf '%s' "$created"
)
# asks <gate>: the gate's question as flow words it, in bold, as advance.sh leads a gate with it.
asks() { printf '**%s**' "$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["gates"][sys.argv[2]]["asks"])' "$flow/profiles.json" "$1")"; }
raise() { in_project "$flow/scripts/gate.sh" raise "$@" > /dev/null; }
claim() { in_project "$flow/scripts/steward.sh" claim "$1" > /dev/null; }

# raise_gates: one item waiting at each gate, each at the step its profile puts after that gate.
raise_gates() (
  raise "$(new_item epic M "Demo: an epic whose spec waits for the owner" epic)" interview "$(asks interview)

1. Should the demo cover Codex as well as Claude?
Recommended: yes, both hosts run flow
2. Does the board need a filter by gate?" grill
  raise "$(new_item task M "Demo: a plan waiting for approval" implement)" plan-approval "$(asks plan-approval)

Two slices: the snapshot field first, then the card that shows it." plan
  raise "$(new_item epic L "Demo: an epic split into tasks" closeout)" decomposition "$(asks decomposition)

Three tasks: the reader (S), the card (M, after the reader), the docs (S)." tasks
  feel="$(new_item task S "Demo: a change to launch and sign off" pr)"
  claim "$feel"
  raise "$feel" feel-test "$(asks feel-test)

Verify passed and the change touches rendered code. Open the board and look at the new chip." implement
  raise "$(new_item task S "Demo: a pull request ready to merge" done)" merge "$(asks merge)

Review and verify passed." pr
  raise "$(new_item bug S "Demo: a step that failed three times" implement)" escalation "$(asks escalation)

The implement step failed three times: the build stays red on a missing import." implement
  raise "$(new_item task S "Demo: a question the code does not answer" implement)" ambiguity "**Which name does the new setting take?**

1. The setting is called refresh in one place and interval in another. Which wins?
Recommended: interval, the name the config already uses" implement \
    --options '[{"label":"interval","text":"Call it interval, as the config does","recommended":true},{"label":"refresh","text":"Call it refresh, as the page does"}]'
  new_item task S "Demo: a ready task to run with the stub agents" none > /dev/null
)

reset_demo
mkdir -p "$demo_dir"
: > "$demo_dir/$MARKER"
write_stubs
build_project
raise_gates
python3 -I -c 'import json, sys; print(json.dumps({"projects": [{"root": sys.argv[1]}]}))' "$project" > "$config"

echo "demo: built $project, its worktrees beside it and one item waiting at each gate"
echo "demo: claude and codex are stubs here; each call is a line in $demo_dir/agents.log"
[ -f "$console/app/ui/dist/index.html" ] || echo "demo: the page is not built, so only the API answers; build it with: npm --prefix '$console/app/ui' run build" >&2
echo "demo: starting the console on port $port for the demo only; Ctrl+C stops it"
cd "$demo_dir"
demo_env node "$daemon" start --project "$project" --port "$port" --state-dir "$state" --config "$config"
