#!/bin/sh
# The console demo: a throwaway flow project and a trial console on it alone, so the console is
# tested without touching a real project.
#   demo.sh [--dir <folder>] [--port <n>]
# Builds <folder> (default $TMPDIR/brain-console-demo) from nothing: a git repo, console-demo/,
# with flow's local adapter and two pool worktrees beside it (console-demo-wt-1, claimed by the
# feel-test item, and console-demo-wt-2, free), one item waiting at each gate (interview,
# plan-approval, decomposition, feel-test, merge, escalation, ambiguity), raised through gate.sh
# as a step would raise it, and one ready item to run on the free worktree. Then it starts this
# checkout's daemon in the foreground on that project only: --project, --port (default 7478,
# never the real console's 7474), --state-dir <folder>/state and --config <folder>/config.json.
# Ctrl+C stops it. Re-running it stops that daemon, deletes <folder> and builds it again.
# Everything runs with HOME=<folder>/home and an environment of PATH, TMPDIR, LANG, USER, SHELL,
# FLOW_PLUGIN and BRAIN_CONSOLE_LAUNCHCTL only, so the owner's console settings,
# BRAIN_CONSOLE_PROJECTS, tokens and a Slack webhook never reach it. <folder>/bin leads the PATH:
# claude and codex there are stubs that log each call to <folder>/agents.log and spend no tokens;
# gh, crontab and launchctl refuse, so the demo never reaches GitHub, the crontab or launchd. The
# flow plugin is the one beside this console (a checkout's plugins/flow), else FLOW_PLUGIN. The
# script deletes only a folder that holds the marker it wrote.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
console="$(cd "$here/.." && pwd)"
DEMO_PORT=7478
REAL_CONSOLE_PORT=7474
MARKER=.brain-console-demo
# What launchctl print exits with for a job it does not have.
LAUNCHCTL_NOT_LOADED=113

die() { echo "demo: $1" >&2; exit "${2:-1}"; }
usage() { die "usage: demo.sh [--dir <folder>] [--port <n>]" 2; }

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
case "$port" in ''|*[!0-9]*) die "--port takes a number, not '$port'" 2 ;; esac
[ "$port" -ne "$REAL_CONSOLE_PORT" ] || die "port $REAL_CONSOLE_PORT is the real console's; give the demo another" 2
case "$demo_dir" in /*) ;; *) demo_dir="$(pwd)/$demo_dir" ;; esac
flow="$console/../flow"
[ -f "$flow/scripts/gate.sh" ] || flow="${FLOW_PLUGIN:-}"
[ -n "$flow" ] && [ -f "$flow/scripts/gate.sh" ] || die "no flow plugin beside this console and none in FLOW_PLUGIN; set FLOW_PLUGIN to one" 2
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

# reset_demo: stops the demo's daemon and deletes the folder, only when this script built it.
reset_demo() {
  [ -e "$demo_dir" ] || return 0
  if [ ! -f "$demo_dir/$MARKER" ]; then
    [ -d "$demo_dir" ] && [ -z "$(ls -A "$demo_dir")" ] && return 0
    die "$demo_dir is not a demo this script built (it has no $MARKER), so it stays; give another --dir" 2
  fi
  # Only with the stub launchctl: the real one would find the owner's console and stop that.
  if [ -f "$state/daemon.pid" ] && [ -x "$stubs/launchctl" ]; then
    (cd "$demo_dir" && demo_env node "$daemon" stop --state-dir "$state" --config "$config") || true
  fi
  rm -rf "$demo_dir"
}

write_stubs() {
  mkdir -p "$stubs"
  cat > "$stubs/claude" <<'STUB'
#!/bin/sh
# claude in the console demo: logs the call to the demo's agents.log and answers as
# claude -p --output-format json would, with no session started and no tokens spent.
printf '%s\t%s\tclaude %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PWD" "$(printf '%s' "$*" | tr '\n' ' ')" >> "$(dirname "$0")/../agents.log"
echo '{"type":"result","subtype":"success","is_error":false,"result":"The demo stub answered: no agent ran and no tokens were spent.","usage":{"input_tokens":0,"output_tokens":0},"total_cost_usd":0}'
STUB
  cat > "$stubs/codex" <<'STUB'
#!/bin/sh
# codex in the console demo: logs the call to the demo's agents.log and answers as
# codex exec --json would, with no session started and no tokens spent.
printf '%s\t%s\tcodex %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PWD" "$(printf '%s' "$*" | tr '\n' ' ')" >> "$(dirname "$0")/../agents.log"
echo '{"type":"item.completed","item":{"type":"agent_message","text":"The demo stub answered: no agent ran and no tokens were spent."}}'
echo '{"type":"turn.completed","usage":{"input_tokens":0,"output_tokens":0}}'
STUB
  for tool in gh crontab launchctl; do
    printf '#!/bin/sh\n# %s in the console demo: refuses, so the demo never reaches GitHub, the crontab or launchd.\necho "%s: a stand-in in the console demo; nothing was read or changed" >&2\n' "$tool" "$tool" > "$stubs/$tool"
  done
  printf '[ "$1" = print ] && exit %s\n' "$LAUNCHCTL_NOT_LOADED" >> "$stubs/launchctl"
  for tool in gh crontab launchctl; do printf 'exit 1\n' >> "$stubs/$tool"; done
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
new_item() {
  created="$(in_project "$flow/adapters/local/create.sh" "$1" "$3" --size "$2" --body "A demo item for testing the console.

## Acceptance
- [ ] The console shows it")"
  [ "$4" = none ] || in_project "$flow/adapters/local/write-state.sh" "$created" "step=$4" > /dev/null
  printf '%s' "$created"
}
# asks <gate>: the gate's question as flow words it, in bold, as advance.sh leads a gate with it.
asks() { printf '**%s**' "$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["gates"][sys.argv[2]]["asks"])' "$flow/profiles.json" "$1")"; }
raise() { in_project "$flow/scripts/gate.sh" raise "$@" > /dev/null; }
claim() { in_project "$flow/scripts/steward.sh" claim "$1" > /dev/null; }

# raise_gates: one item waiting at each gate, each at the step its profile puts after that gate.
raise_gates() {
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
}

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
