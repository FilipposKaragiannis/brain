#!/bin/sh
# The console demo: a throwaway flow project and a trial console on it alone, so the console is
# tested without touching a real project. It fills every screen: gates, a live and a dead run, a
# session of the owner's, job schedules and history, a stopped host, two weeks of step runs for
# the graph report. Re-running it stops that console, the runs it started and its fake agents,
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
# How long a fake agent sleeps before it ends by itself, should nothing stop it: a day.
FAKE_AGENT_SECONDS=86400
# The demo folder's list of the fake agents it started, one pid a line, so this run's exit and a
# re-run can stop them. A file, not a variable: a helper that starts one runs in a subshell.
AGENT_PIDS=agents.pids
# The parts of the caller's home the demo's home never links to (see link_home): the agents' own
# folders, the console's settings, state, install and launcher, the launch agents a job install
# writes, and git's identity, which the demo sets itself. A name also holds out the names that
# extend it after a dot, such as .claude.json.backup.
HELD_OUT=".claude .claude.json .codex .config/brain-console .config/git .gitconfig .local/bin/brain-console .local/share/brain-console .local/state/brain-console Library/LaunchAgents"
# The shell startup files the demo's home has its own of (see write_shell_startup), each the last
# its shell reads in a mode a pane opens: zsh's .zshrc (interactive) and .zlogin (login), bash's
# .bashrc, and sh's .profile. Bash's .bash_profile comes on top, as it reads the caller's first.
SHELL_STARTUP=".zshrc .zlogin .bashrc .profile"

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
# ps and lsof give an agent's folder with every link resolved (/private/var for /var on macOS), and
# the console places an agent by that folder against the project's path as given, so the demo's
# path is the physical one.
mkdir -p "$(dirname "$demo_dir")"
demo_dir="$(cd "$(dirname "$demo_dir")" && pwd -P)/$(basename "$demo_dir")"
caller_home="${HOME:-}"
flow="$console/../flow"
[ -f "$flow/scripts/gate.sh" ] || flow="${FLOW_PLUGIN:-}"
[ -n "$flow" ] && [ -f "$flow/scripts/gate.sh" ] || die "no flow plugin beside this console and none in FLOW_PLUGIN; set FLOW_PLUGIN to one" "$USAGE_EXIT"
flow="$(cd "$flow" && pwd)"
# process_command and process_group: ps, or pgrep and python where a sandbox refuses ps.
. "$flow/lib/process.sh"
perl="$(command -v perl)" || die "the demo's fake agents run perl, and none is on PATH"

home="$demo_dir/home"
stubs="$demo_dir/bin"
project="$demo_dir/console-demo"
state="$demo_dir/state"
config="$demo_dir/config.json"
daemon="$console/app/daemon/src/main.ts"

# demo_env <command...>: the command with the demo's environment and nothing else.
demo_env() {
  env -i HOME="$home" PATH="$stubs:$PATH" TMPDIR="$temporary" LANG=C USER="${USER:-demo}" SHELL="${SHELL:-/bin/sh}" \
    FLOW_PLUGIN="$flow" BRAIN_CONSOLE_LAUNCHCTL="$stubs/launchctl" \
    ${BRAIN_CONSOLE_TERMINAL_LOOK:+BRAIN_CONSOLE_TERMINAL_LOOK="$BRAIN_CONSOLE_TERMINAL_LOOK"} "$@"
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
    case "$(process_command "$pid")" in *jobs/*.sh*) ;; *) continue ;; esac
    [ "$(process_group "$pid")" = "$pid" ] || continue
    case "$(cwd_of "$pid")/" in "$real"/*) echo "$pid" ;; esac
  done
}
# group_alive <group...>: whether any process in the groups runs. `kill -s 0`, as the TERM and KILL
# below: dash's kill takes `--` after `-s <signal>` but reads `-0 --` as a bad number.
group_alive() { for g in "$@"; do kill -s 0 -- "-$g" 2>/dev/null && return 0; done; return 1; }
# wait_groups <group...>: waits, a bounded while, for every process in the groups to end.
wait_groups() {
  waited=0
  while group_alive "$@" && [ "$waited" -lt "$RUN_STOP_POLLS" ]; do sleep "$RUN_STOP_POLL_SECONDS"; waited=$((waited + 1)); done
}
# stop_groups <group...>: ends each whole group, as the daemon's stop does: SIGTERM, then SIGKILL
# after the grace.
stop_groups() {
  [ $# -gt 0 ] || return 0
  for g in "$@"; do kill -s TERM -- "-$g" 2>/dev/null || true; done
  wait_groups "$@"
  group_alive "$@" || return 0
  for g in "$@"; do kill -s KILL -- "-$g" 2>/dev/null || true; done
  wait_groups "$@"
  ! group_alive "$@" || die "a process the demo started outlived SIGKILL (process groups $*), so the demo stays; stop it and run this again"
}
# stop_demo_runs: the daemon leaves detached runs going by design, so a run the demo's console
# started would work on the folder about to be deleted and on the items rebuilt with its ids.
# The command substitution splits on purpose: one pid a line.
stop_demo_runs() { stop_groups $(demo_run_pids); }
# demo_agent_pids <pid...>: those of the pids that are still a fake agent of the demo: each leads
# its own session and runs perl under the name claude, sleeping, in the demo folder, so a pid since
# reused never reaches another process.
demo_agent_pids() {
  real="$(cd "$demo_dir" && pwd -P)"
  for pid in "$@"; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    case "$(process_command "$pid")" in "claude -e sleep $FAKE_AGENT_SECONDS "*) ;; *) continue ;; esac
    [ "$(process_group "$pid")" = "$pid" ] || continue
    case "$(cwd_of "$pid")/" in "$real"/*) echo "$pid" ;; esac
  done
}
# stop_demo_agents <pid...>: ends those of the pids that are still a fake agent of the demo.
stop_demo_agents() { stop_groups $(demo_agent_pids "$@"); }
record_agent() { echo "$1" >> "$demo_dir/$AGENT_PIDS"; }
stop_recorded_agents() {
  if [ -f "$demo_dir/$AGENT_PIDS" ]; then stop_demo_agents $(cat "$demo_dir/$AGENT_PIDS"); fi
}
# reset_demo: deletes the folder only when this script built it, after stopping what it started.
reset_demo() {
  [ -e "$demo_dir" ] || return 0
  is_empty_dir "$demo_dir" && return 0
  refuse_foreign_dir
  stop_demo_daemon
  stop_demo_runs
  stop_recorded_agents
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

# build_project: the repo, flow installed by its own init with two job schedules, and the four
# pool worktrees: one for the gate with a session, one for the live run, one for the dead run and
# one free for the ready task.
build_project() {
  mkdir -p "$home" "$project/.flow"
  printf '[user]\n\tname = Console Demo\n\temail = demo@example.com\n' > "$home/.gitconfig"
  in_project git init -q -b main
  printf '# Console demo\n\nA throwaway flow project that plugins/console/scripts/demo.sh builds to test the console on.\nRe-running the script deletes it.\n' > "$project/README.md"
  in_project git add README.md
  in_project git commit -q -m "chore: the console demo"
  printf 'adapters:\n  default: local\nbase: main\nnotify:\n  desktop: false\njobs:\n  schedule:\n    next: every 30m\n    health: daily 02:00\n' > "$project/.flow/config.yaml"
  in_project sh "$flow/skills/init/scripts/init.sh" > /dev/null
  for n in 1 2 3 4; do in_project "$flow/scripts/steward.sh" add "../console-demo-wt-$n" > /dev/null; done
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
# claim <item>: claims a pool worktree for the item; prints its path.
claim() { in_project "$flow/scripts/steward.sh" claim "$1"; }
# item_file <item>: the item's file name in flow's runs folder, as flow's item_slug makes it.
item_file() { printf '%s.json' "$(printf '%s' "$1" | tr ':/#' '---')"; }

# json_line <key=text | key:=json>...: one JSON object on a line, compact as flow writes its records.
json_line() {
  python3 -I -c 'import json, sys
record = {}
for pair in sys.argv[1:]:
    key, value = pair.split("=", 1)
    if key.endswith(":"): record[key[:-1]] = json.loads(value)
    else: record[key] = value
print(json.dumps(record, separators=(",", ":")))' "$@"
}
# minutes_ago <n>: the UTC time n minutes ago, as flow writes a time.
minutes_ago() { python3 -I -c 'import datetime, sys; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
session_id() { python3 -I -c 'import uuid; print(uuid.uuid4())'; }
# transcript <folder> <session id> <minutes ago> <user turn> <assistant turn>...: the claude
# transcript of a session in <folder>, where claude keeps it in the demo's home: the user's turn
# <minutes ago>, then the assistant's turns spread from there to now. Compact JSON, since the
# console finds a transcript's start by its first `"timestamp":"…"`.
transcript() {
  python3 -I -c 'import datetime, json, os, re, sys
home, folder, session, minutes, turns = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), sys.argv[5:]
projects = os.path.join(home, ".claude", "projects", re.sub("[^A-Za-z0-9]", "-", folder))
os.makedirs(projects, exist_ok=True)
start = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=minutes)
spacing = datetime.timedelta(minutes=minutes) / len(turns)
with open(os.path.join(projects, session + ".jsonl"), "w") as out:
    for index, text in enumerate(turns):
        role = "user" if index == 0 else "assistant"
        at = (start + spacing * index).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        entry = {"type": role, "timestamp": at, "sessionId": session, "cwd": folder, "message": {"role": role, "content": [{"type": "text", "text": text}]}}
        out.write(json.dumps(entry, separators=(",", ":")) + "\n")' "$home" "$@"
}
# start_fake_agent <folder> <argument...>: prints the pid of a process ps lists as
# `claude -e sleep … -- <arguments>` in <folder>, which the console takes for a claude: perl under
# the name claude, sleeping, with no agent and no tokens. It leads a session of its own and lets go
# of the output, so the capture of its pid returns at once and no shell's exit ends it.
start_fake_agent() (
  cd "$1" && shift && python3 -I -c 'import os, sys
if os.fork(): os._exit(0)
os.setsid()
print(os.getpid(), flush=True)
null = os.open(os.devnull, os.O_RDWR)
for descriptor in (0, 1, 2): os.dup2(null, descriptor)
os.execv(sys.argv[1], sys.argv[2:])' "$perl" claude -e "sleep $FAKE_AGENT_SECONDS" -- "$@"
)

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
  feel_worktree="$(claim "$feel")"
  # Raised as a claude session raises it (flow's host_name reads CLAUDECODE), so the console looks
  # for the session among claude's transcripts.
  in_project env CLAUDECODE=1 "$flow/scripts/gate.sh" raise "$feel" feel-test "$(asks feel-test)

Verify passed and the change touches rendered code. Open the board and look at the new chip." implement > /dev/null
  # The session that raised it, ended: its transcript in the claimed worktree, started before the
  # raise, so Discuss with the agent resumes it.
  transcript "$feel_worktree" "$(session_id)" 20 "/flow:next $feel" \
    "Verify passed: lint, unit and the page build." \
    "The change touches rendered code, so it needs a feel test. Raised the feel-test gate: open the board and look at the new chip."
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

# The Agents screen. add_live_run: a claimed item, its run record and a headless claude in its
# worktree with a sessions file and a transcript; prints the item.
add_live_run() (
  mkdir -p "$home/.claude/sessions" "$project/.flow/runs"
  live="$(new_item task S "Demo: a run going now" implement)"
  worktree="$(claim "$live")"
  pid="$(start_fake_agent "$worktree" -p "/flow:next $live")"
  record_agent "$pid"
  session="$(session_id)"
  json_line "pid:=$pid" "sessionId=$session" "cwd=$worktree" status=busy "statusUpdatedAt:=$(date +%s)000" > "$home/.claude/sessions/$pid.json"
  transcript "$worktree" "$session" 12 "/flow:next $live" \
    "Reading the plan: one slice, the chip on the board card." \
    "Wrote the failing test: the card shows the chip while a run goes." \
    "Added the chip to the card. The test passes." \
    "Running the checks: lint, unit and the page build."
  json_line "item=$live" step=implement profile=task "worktree=$worktree" host=claude "started=$(minutes_ago 12)" "pid:=$pid" > "$project/.flow/runs/$(item_file "$live")"
  printf '%s' "$live"
)
# add_dead_run: a claimed item and a codex run record three hours old with no process; prints the item.
add_dead_run() (
  mkdir -p "$project/.flow/runs"
  dead="$(new_item task S "Demo: a run whose process died" implement)"
  json_line "item=$dead" step=implement profile=task "worktree=$(claim "$dead")" host=codex "started=$(minutes_ago 180)" > "$project/.flow/runs/$(item_file "$dead")"
  printf '%s' "$dead"
)
# add_owner_session: one of the owner's own sessions in the project root, with a transcript but no
# sessions file.
add_owner_session() (
  pid="$(start_fake_agent "$project" --model opus)"
  record_agent "$pid"
  transcript "$project" "$(session_id)" 30 "What does the console show for a run that died?" \
    "A dead-run card on Agents, with Resume, and a row in Needs you."
)

# add_jobs <live item> <dead item>: what the Jobs screen shows besides the schedules in the config:
# codex stopped on a spend limit during the dead run, and the jobs' run history, oldest first.
add_jobs() {
  mkdir -p "$project/.flow/log"
  json_line host=codex cause=spend-limit "said=You have hit your usage limit. Try again at 3:00 PM." "at=$(minutes_ago 25)" "item=$2" > "$project/.flow/log/codex.stopped"
  {
    json_line job=health host=claude "at=$(minutes_ago 540)" seconds:=14 exit:=0 "result=healthy: 4 worktrees, 0 stale"
    json_line job=next host=claude "at=$(minutes_ago 95)" seconds:=2 exit:=0 "result=quiet: nothing ready"
    json_line job=next host=codex "at=$(minutes_ago 65)" seconds:=96 exit:=1 "result=stopped: spend limit"
    json_line job=next host=claude "at=$(minutes_ago 35)" seconds:=1412 exit:=0 "result=advanced $1 to implement"
    json_line job=next host=claude "at=$(minutes_ago 5)" seconds:=0 exit:=0 "result=skipped: a run of $1 still goes"
  } >> "$project/.flow/log/runs.jsonl"
}

# step_line <item> <step> <minutes ago> <seconds> <exit> <cost in dollars>: one step run as flow's
# host_record writes it to the run log.
step_line() {
  json_line "item=$1" "step=$2" host=claude model= effort= "at=$(minutes_ago "$3")" "seconds:=$4" "exit:=$5" usage:={} "cost_usd:=$6" models:=[] result=
}

# add_step_runs <live item> <dead item>: what the Graph report screen shows: last week's verify
# runs and this week's, four times slower at the median, and this week's implement runs, two per
# item with one failed.
add_step_runs() {
  minutes_per_day=1440
  mkdir -p "$project/.flow/log"
  {
    for days_ago in 12 10 9; do step_line "$2" verify "$((days_ago * minutes_per_day))" 300 0 0.20; done
    for days_ago in 5 3 2; do step_line "$1" verify "$((days_ago * minutes_per_day))" 1200 0 0.20; done
    step_line "$1" implement "$((6 * minutes_per_day))" 900 1 1.40
    step_line "$1" implement "$((5 * minutes_per_day))" 1500 0 2.10
    step_line "$2" implement "$((4 * minutes_per_day))" 600 0 0.90
    step_line "$2" implement "$((3 * minutes_per_day))" 720 0 1.10
  } >> "$project/.flow/log/runs.jsonl"
}

# held_out <path in the home>: `held` when HELD_OUT holds it out, `above` when it holds out
# something inside it, else nothing.
held_out() {
  for out in $HELD_OUT; do
    case "$1" in "$out"|"$out".*) echo held; return 0 ;; esac
    case "$out" in "$1"/*) echo above; return 0 ;; esac
  done
}
# left_out <entry>: a glob that matched nothing, or an entry that holds the demo folder, which the
# demo's home must not loop back into.
left_out() {
  [ -e "$1" ] || [ -L "$1" ] || return 0
  case "$demo_dir/" in "$1"/*) return 0 ;; esac
  return 1
}
# link_entry <entry> <link>: an entry the demo made itself (its git identity, its shell startup
# files) stays.
link_entry() { [ -e "$2" ] || [ -L "$2" ] || ln -s "$1" "$2"; }
# link_above <entry> <the demo's folder> <its path in the home>/: an entry above a held-out one
# becomes a folder of the demo's own, linked into in turn.
link_above() {
  [ -d "$1" ] || return 0
  mkdir -p "$2" && link_home "$1" "$2" "$3"
}
# link_home <the caller's folder> <the demo's folder> [<their path in the home>/]: links each
# entry of the caller's home into the demo's, so a pane's shell there loads the owner's terminal
# settings and what their shell setup reads, except what HELD_OUT holds out.
link_home() (
  for entry in "$1"/.[!.]* "$1"/..?* "$1"/*; do
    left_out "$entry" && continue
    name="${entry##*/}"
    case "$(held_out "${3:-}$name")" in
      held) ;;
      above) link_above "$entry" "$2/$name" "${3:-}$name/" ;;
      *) link_entry "$entry" "$2/$name" ;;
    esac
  done
)
# sh_word <text>: the text in single quotes, as one word a shell reads back unchanged.
sh_word() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
# write_shell_startup <file> <the caller's file...>: the demo's own <file> sources the first of the
# caller's files there is, then puts the stubs first on PATH again: the caller's setup, or macOS's
# path_helper, can put the real claude ahead of them, and a pane must run no real agent.
write_shell_startup() {
  file="$1"; shift
  keyword=if
  {
    echo "# The console demo's $file: yours, then its stub agents first on PATH, so a pane spends no tokens."
    for startup in "$@"; do
      printf '%s [ -f %s ]; then . %s\n' "$keyword" "$(sh_word "$caller_home/$startup")" "$(sh_word "$caller_home/$startup")"
      keyword=elif
    done
    printf 'fi\nPATH=%s:"$PATH"\n' "$(sh_word "$stubs")"
  } > "$home/$file"
}
# share_home: the demo's home gets the caller's, its own shell startup files first so they stay.
share_home() {
  for file in $SHELL_STARTUP; do write_shell_startup "$file" "$file"; done
  write_shell_startup .bash_profile .bash_profile .bash_login .profile
  link_home "$caller_home" "$home"
}

reset_demo
mkdir -p "$demo_dir"
: > "$demo_dir/$MARKER"
write_stubs
build_project
raise_gates
# The fake agents end with this run, by Ctrl+C, a signal or the daemon's stop; a re-run ends any left.
trap stop_recorded_agents EXIT
trap 'exit 1' INT TERM HUP
live="$(add_live_run)"
dead="$(add_dead_run)"
add_owner_session
add_step_runs "$live" "$dead"
add_jobs "$live" "$dead"
[ -z "$caller_home" ] || [ ! -d "$caller_home" ] || share_home
python3 -I -c 'import json, sys; print(json.dumps({"projects": [{"root": sys.argv[1]}]}))' "$project" > "$config"

echo "demo: built $project, its worktrees beside it, one item waiting at each gate, a live run, a dead run, a session of yours and two weeks of step runs"
echo "demo: the agents are fake processes that end with the demo; a pane's shell gets your home and shell setup, with the stubs first on PATH and without the agents' folders or the console's settings"
echo "demo: claude and codex are stubs here; each call is a line in $demo_dir/agents.log"
[ -f "$console/app/ui/dist/index.html" ] || echo "demo: the page is not built, so only the API answers; build it with: npm --prefix '$console/app/ui' run build" >&2
echo "demo: starting the console on port $port for the demo only; Ctrl+C stops it"
cd "$demo_dir"
demo_env node "$daemon" start --project "$project" --port "$port" --state-dir "$state" --config "$config"
