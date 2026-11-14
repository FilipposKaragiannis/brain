#!/bin/sh
# Tests for the console plugin's installer and `brain-console update`: install.sh runs under a
# fake home with a fake npm that records its calls (and builds a stand-in page), a launchctl
# that says nothing is loaded, and no network. demo.sh builds its demo in a temp folder and hands
# the daemon to a fake node that records its arguments and environment, so no daemon starts. When
# the app's dev dependencies are present, demo.sh also starts the real daemon on a free port, and
# the tests stop it before they end.
# Needs node 24 or newer (the installer refuses an older one), else it skips. Run from anywhere.
# Exit 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$here/.." && pwd)"
major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if [ "$major" -lt 24 ]; then echo "console tests: node 24 or newer missing, skipping"; exit 0; fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { # check <name> <condition command...>
  name="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi
}

home="$work/home"; mkdir -p "$home"
fake="$work/bin"; mkdir -p "$fake"
# npm: logs "<cwd> <args>"; `ci` leaves a marker, `run build` leaves ui/dist/index.html.
cat > "$fake/npm" <<SH
#!/bin/sh
echo "\$(pwd) \$*" >> "$work/npm.log"
dir=.; [ "\$1" = --prefix ] && { dir="\$2"; shift 2; }
[ "\$1" = ci ] && [ -f "$work/npm-fails" ] && exit 1
case "\$1" in
  ci) mkdir -p "\$dir/node_modules" && : > "\$dir/node_modules/.fake" ;;
  run) [ "\$2" = build ] && mkdir -p "\$dir/dist" && echo '<html></html>' > "\$dir/dist/index.html" ;;
esac
SH
for tool in launchctl open; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/offline.log"\n[ "$1" = print ] && exit 113\nexit 0\n' "$tool" "$work" > "$fake/$tool"
done
chmod +x "$fake"/*
run_install() { # run_install <script> <args...>: under the fake home, output in $work/out
  script="$1"; shift
  env -i HOME="${H:-$home}" PATH="$fake:$PATH" SHELL=/bin/zsh TMPDIR="${TMPDIR:-/tmp}" ${BCH:+BRAIN_CONSOLE_HOME="$BCH"} sh "$script" "$@" > "$work/out" 2>&1
}
share="$home/.local/share/brain-console"
launcher="$home/.local/bin/brain-console"
version="$(node -p 'require(process.argv[1]).version' "$P/app/package.json")"

# A copy of the plugin at another version, as the plugin cache holds it.
cached() { # cached <version>: prints its folder
  dir="$home/.claude/plugins/cache/brain-plugins/console/$1"
  mkdir -p "$dir"
  (cd "$P" && tar -cf - --exclude node_modules --exclude dist scripts app) | (cd "$dir" && tar -xf -)
  node -e 'const fs=require("fs"); const f=process.argv[1]; const p=JSON.parse(fs.readFileSync(f,"utf8")); p.version=process.argv[2]; fs.writeFileSync(f, JSON.stringify(p, null, 2))' "$dir/app/package.json" "$1"
  echo "$dir"
}

echo "install.sh"
run_install "$P/scripts/install.sh" --no-launchd; code=$?
check "a first install succeeds" [ "$code" -eq 0 ]
check "the app lands in a folder named for its version" test -f "$share/$version/daemon/src/main.ts"
check "current points at that version" [ "$(readlink "$share/current")" = "$version" ]
check "the source's node_modules are not copied" sh -c "[ ! -e '$share/$version/node_modules/typescript' ] && [ -f '$share/$version/node_modules/.fake' ]"
check "npm ci runs in the new copy before it takes the version's place" grep -q "^$share/\.install-$version-[0-9]* ci --no-audit --no-fund\$" "$work/npm.log"
check "the UI's dependencies are installed and the page built" sh -c "grep -q -- '--prefix ui ci' '$work/npm.log' && grep -q -- '--prefix ui run build' '$work/npm.log' && [ -f '$share/$version/ui/dist/index.html' ]"
check "no temp folder is left beside the versions" [ "$(find "$share" -maxdepth 1 -name '.install-*' | wc -l | tr -d ' ')" -eq 0 ]
check "the launcher is executable" test -x "$launcher"
check "the launcher is two lines that run the current link" sh -c "[ \"\$(wc -l < '$launcher' | tr -d ' ')\" -eq 2 ] && [ \"\$(sed -n 2p '$launcher')\" = 'exec node \"\$HOME/.local/share/brain-console/current/daemon/src/main.ts\" \"\$@\"' ]"
check "the launcher runs the installed command" [ "$(HOME="$home" PATH="$fake:$PATH" "$launcher" version)" = "$version" ]
check "a launcher dir off the PATH gets the line to add" grep -q 'export PATH="\$HOME/.local/bin:\$PATH"' "$work/out"
check "the profile named is the shell's" grep -q '~/.zshrc' "$work/out"
check "--no-launchd leaves launchd alone" sh -c "! grep -q 'bootstrap' '$work/offline.log'"
check "it ends with the status" grep -q "^brain-console $version\$" "$work/out"

project="$work/project"; mkdir -p "$project/.flow" "$project/.git"; : > "$project/.flow/config.yaml"
run_install "$P/scripts/install.sh" --no-launchd --project "$project"; code=$?
check "--project adds the folder to the settings" sh -c "[ $code -eq 0 ] && grep -q '\"root\": \"$project\"' '$home/.config/brain-console/config.json'"
run_install "$P/scripts/install.sh" --no-launchd --project "$work"; code=$?
check "--project on a folder with no flow fails the install" [ "$code" -eq 1 ]
run_install "$P/scripts/install.sh" --bogus; code=$?
check "an unknown argument exits 2" [ "$code" -eq 2 ]

echo "install.sh: failures and reinstalls"
: > "$work/npm-fails"
run_install "$P/scripts/install.sh" --no-launchd; code=$?
rm -f "$work/npm-fails"
check "a failed npm ci fails the install" [ "$code" -eq 1 ]
check "a failed npm ci leaves current alone" [ "$(readlink "$share/current")" = "$version" ]
check "a failed npm ci leaves no staging folder" [ "$(find "$share" -maxdepth 1 -name '.install-*' | wc -l | tr -d ' ')" -eq 0 ]
mkdir -p "$share/.install-0.0.1-99/app" "$share/.old-0.0.1-98"
: > "$share/$version/marker"
run_install "$P/scripts/install.sh" --no-launchd; code=$?
check "the same version installs again" sh -c "[ $code -eq 0 ] && [ \"\$(readlink '$share/current')\" = '$version' ] && [ -f '$share/$version/daemon/src/main.ts' ]"
check "the same version again replaces the copy instead of keeping its files" [ ! -e "$share/$version/marker" ]
check "folders a killed run left behind are cleaned up" [ "$(find "$share" -maxdepth 1 -name '.*-*' | wc -l | tr -d ' ')" -eq 0 ]
bad="$work/badversion"; mkdir -p "$bad"
(cd "$P" && tar -cf - --exclude node_modules --exclude dist scripts app) | (cd "$bad" && tar -xf -)
node -e 'const fs=require("fs"); const f=process.argv[1]; const p=JSON.parse(fs.readFileSync(f,"utf8")); p.version="../x"; fs.writeFileSync(f, JSON.stringify(p))' "$bad/app/package.json"
run_install "$bad/scripts/install.sh" --no-launchd; code=$?
check "a version that is not digits and dots exits 2" sh -c "[ $code -eq 2 ] && grep -q 'no version of digits and dots' '$work/out' && [ ! -e '$home/.local/share/x' ]"

other="$work/other"
(BCH="$other"; run_install "$P/scripts/install.sh" --no-launchd); code=$?
olauncher="$other/.local/bin/brain-console"
check "BRAIN_CONSOLE_HOME moves the whole install" sh -c "[ $code -eq 0 ] && [ -f '$other/.local/share/brain-console/$version/daemon/src/main.ts' ] && [ -x '$olauncher' ]"
check "a launcher for another home keeps BRAIN_CONSOLE_HOME" sh -c "[ \"\$(sed -n 2p '$olauncher')\" = 'BRAIN_CONSOLE_HOME=\"$other\"; export BRAIN_CONSOLE_HOME' ] && [ \"\$(sed -n 3p '$olauncher')\" = 'exec node \"$other/.local/share/brain-console/current/daemon/src/main.ts\" \"\$@\"' ]"
check "the PATH hint names that home's bin folder" grep -q "export PATH=\"$other/.local/bin:\$PATH\"" "$work/out"

fresh="$work/fresh"; mkdir -p "$fresh"
(H="$fresh"; run_install "$P/scripts/install.sh" --no-launchd) > /dev/null
fshare="$fresh/.local/share/brain-console"
mv "$fshare/$version" "$fshare/0.0.9" && ln -sfn 0.0.9 "$fshare/current"
(H="$fresh"; run_install "$P/scripts/install.sh"); code=$?
check "a launch agent that cannot start fails the install" sh -c "[ $code -eq 1 ] && grep -q 'no projects' '$work/out'"
check "a failed launch agent points current back at the version before" sh -c "[ \"\$(readlink '$fshare/current')\" = 0.0.9 ] && grep -q 'current points back at 0.0.9' '$work/out'"
check "nothing is pruned after a failed launch agent" test -d "$fshare/0.0.9"
mkdir -p "$fresh/Library/LaunchAgents"
printf '<plist><dict><key>ProgramArguments</key>\n<array>\n<string>/n</string>\n<string>/m.ts</string>\n<string>start</string>\n<string>--project</string>\n<string>%s</string>\n</array></dict></plist>\n' "$project" > "$fresh/Library/LaunchAgents/com.brain.console.plist"
(H="$fresh"; run_install "$P/scripts/install.sh" --no-launchd --project "$project"); code=$?
check "--project over an agent with --project flags is refused" sh -c "[ $code -eq 1 ] && grep -q \"launch agent's --project flags\" '$work/out'"

keep="$(cached 0.8.0)"
run_install "$keep/scripts/install.sh" --no-launchd --keep-old; code=$?
check "--keep-old keeps the version before" sh -c "[ $code -eq 0 ] && [ \"\$(readlink '$share/current')\" = 0.8.0 ] && [ -d '$share/$version' ]"
rm -rf "$keep"

nobin="$work/nobin"; mkdir -p "$nobin"
if ! env PATH="/bin:/usr/bin" sh -c "command -v node" >/dev/null 2>&1; then
  env -i HOME="$home" PATH="/bin:/usr/bin" sh "$P/scripts/install.sh" --no-launchd > "$work/out" 2>&1; code=$?
  check "without node it exits 2 naming what to install" sh -c "[ $code -eq 2 ] && grep -q 'node is missing; install Node 24' '$work/out'"
else
  echo "  skip without node: /usr/bin has a node"
fi
ln -s "$(command -v node)" "$nobin/node"
env -i HOME="$home" PATH="$nobin:/bin:/usr/bin" sh "$P/scripts/install.sh" --no-launchd > "$work/out" 2>&1; code=$?
if env PATH="$nobin:/bin:/usr/bin" sh -c "command -v npm" >/dev/null 2>&1; then echo "  skip without npm: /usr/bin has an npm"; else
  check "without npm it exits 2 naming what to install" sh -c "[ $code -eq 2 ] && grep -q 'npm is missing' '$work/out'"
fi

echo "update"
cached 0.9.0 > /dev/null
newest="$(cached 0.10.0)"
mkdir -p "$home/.claude/plugins/cache/brain-plugins/console/0.11.0"   # no install script: not a plugin
env -i HOME="$home" PATH="$fake:$PATH" TMPDIR="${TMPDIR:-/tmp}" "$launcher" update > "$work/out" 2>&1; code=$?
check "update succeeds" [ "$code" -eq 0 ]
check "update installs the newest cached version by number" sh -c "grep -q 'to 0.10.0 from $newest\$' '$work/out' && [ \"\$(readlink '$share/current')\" = 0.10.0 ]"
check "the versions installed before are removed" sh -c "[ ! -e '$share/$version' ] && [ ! -e '$share/0.8.0' ]"
check "the only version left is the new one" [ "$(ls "$share")" = "0.10.0
current" ]
check "the launcher now runs the new version" [ "$(HOME="$home" PATH="$fake:$PATH" "$launcher" version)" = 0.10.0 ]
env -i HOME="$home" PATH="$fake:$PATH" TMPDIR="${TMPDIR:-/tmp}" "$launcher" update > "$work/out" 2>&1; code=$?
check "update with nothing newer is already up to date" sh -c "[ $code -eq 0 ] && grep -q 'already up to date' '$work/out' && [ \"\$(readlink '$share/current')\" = 0.10.0 ]"
check "update leaves launchd alone when no job is loaded" sh -c "! grep -qE 'bootstrap|kickstart' '$work/offline.log'"

echo "demo.sh"
# node: records the daemon's arguments and environment instead of starting it.
nodebin="$work/nodebin"; mkdir -p "$nodebin"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/node.args"\nenv > "%s/node.env"\n' "$work" "$work" > "$nodebin/node"
chmod +x "$nodebin/node"
demo="$work/demo"
demo_port=7499
usage_exit="$(sed -n 's/^USAGE_EXIT=//p' "$P/scripts/demo.sh")"
run_demo() { # run_demo <args...>: under the fake home, with a real-looking project list in the environment
  env -i HOME="$home" PATH="$nodebin:$PATH" TMPDIR="${TMPDIR:-/tmp}" BRAIN_CONSOLE_PROJECTS="$project" \
    sh "$P/scripts/demo.sh" "$@" > "$work/out" 2>&1
}
in_demo() { # in_demo <command...>: in the demo project, with the PATH the daemon was given
  (cd "$demo/console-demo" && env -i HOME="$demo/home" PATH="$(sed -n 's/^PATH=//p' "$work/node.env")" FLOW_PLUGIN="$P/../flow" "$@")
}
gate_kinds() { python3 -I -c 'import json, sys; print("\n".join(json.load(open(sys.argv[1]))["gates"]))' "$P/../flow/profiles.json" | sort; }
agent_calls() { cat "$demo/agents.log" 2>/dev/null | wc -l | tr -d ' '; }
run_demo --dir "$demo" --port "$demo_port"; code=$?
check "the demo builds" [ "$code" -eq 0 ]
check "the demo project is a git repo with a commit on main" in_demo git rev-parse --verify -q refs/heads/main
check "the demo project has two worktrees besides its own" [ "$(in_demo git worktree list | wc -l | tr -d ' ')" -eq 3 ]
check "the demo project runs on flow's local adapter" sh -c "sed -n '/^adapters:/,/^[a-z]/p' '$demo/console-demo/.flow/config.yaml' | grep -q 'default: local'"
check "one gate of each kind waits" [ "$(in_demo sh "$P/../flow/scripts/gate.sh" list | cut -f3 | sort)" = "$(gate_kinds)" ]
check "the demo has one ready item to run" python3 -c "import json, sys; sys.exit(len(json.loads(sys.argv[1])) != 1)" "$(in_demo sh "$P/../flow/adapters/local/list-ready.sh")"
check "claude on the daemon's PATH is the demo's stub" [ "$(in_demo sh -c 'command -v claude')" = "$demo/bin/claude" ]
check "codex on the daemon's PATH is the demo's stub" [ "$(in_demo sh -c 'command -v codex')" = "$demo/bin/codex" ]
# The stubs run by path: a broken PATH must never reach a real claude, codex, gh, crontab or launchctl.
calls_before="$(agent_calls)"
in_demo "$demo/bin/claude" -p "a prompt" --output-format json > "$work/stub.json"
check "the stub claude reports no tokens spent" python3 -c "import json, sys; usage = json.load(open(sys.argv[1]))['usage']; sys.exit(sum(usage.values()) != 0)" "$work/stub.json"
check "the stub claude logs each call" [ "$(agent_calls)" -gt "$calls_before" ]
calls_before="$(agent_calls)"
in_demo "$demo/bin/codex" exec --json "a prompt" > "$work/stub.jsonl"
check "the stub codex reports no tokens spent" python3 -c "import json, sys; usages = [event['usage'] for event in map(json.loads, open(sys.argv[1])) if 'usage' in event]; sys.exit(not usages or any(sum(usage.values()) for usage in usages))" "$work/stub.jsonl"
check "the stub codex logs each call" [ "$(agent_calls)" -gt "$calls_before" ]
for tool in gh crontab launchctl; do
  check "$tool on the daemon's PATH is the demo's stub" [ "$(in_demo sh -c "command -v $tool")" = "$demo/bin/$tool" ]
  in_demo "$demo/bin/$tool" list > /dev/null 2>&1; code=$?
  check "the stub $tool refuses" [ "$code" -ne 0 ]
done
# The command line is what demo.sh hands the daemon, so it is the script's output here; the fake
# node stands in so no daemon starts. The real-daemon block below checks the outcome when it can.
check "the daemon starts on the demo project, port, state dir and config only" [ "$(cat "$work/node.args")" = "$P/app/daemon/src/main.ts
start
--project
$demo/console-demo
--port
$demo_port
--state-dir
$demo/state
--config
$demo/config.json" ]
check "the daemon's home is the demo's" grep -qx "HOME=$demo/home" "$work/node.env"
check "the caller's BRAIN_CONSOLE_PROJECTS never reaches the daemon" sh -c "! grep -q '^BRAIN_CONSOLE_PROJECTS=' '$work/node.env'"
check "the console settings file names the demo project only" python3 -c "import json, sys; sys.exit(json.load(open(sys.argv[1]))['projects'] != [{'root': sys.argv[2]}])" "$demo/config.json" "$demo/console-demo"
: > "$demo/console-demo/left-behind"
run_demo --dir "$demo"; code=$?
check "a second run succeeds" [ "$code" -eq 0 ]
check "a second run resets the demo" [ ! -e "$demo/console-demo/left-behind" ]
check "the reset demo has one gate of each kind again" [ "$(in_demo sh "$P/../flow/scripts/gate.sh" list | cut -f3 | sort)" = "$(gate_kinds)" ]
# A detached run as the console's run.start leaves one: a flow job leading its own process group,
# its pid in a lock under the project's .flow/log, a child in its group. The daemon's stop leaves
# it going, so the re-run must end it, child too, before the folder goes.
fake_job="$work/fakeflow/jobs/next.sh"; mkdir -p "$(dirname "$fake_job")"
printf '#!/bin/sh\nmkdir -p "$1" && echo $$ > "$1/pid"\nsleep 300 &\necho $! > "$2"\nwait\n' > "$fake_job"
# A job that outlasts SIGTERM by a second and, as it ends, notes in <child pid file>.end whether
# its lock in the demo is still there: kept when the re-run waited for it, gone when it did not.
slow_job="$work/fakeflow/jobs/slow.sh"
cat > "$slow_job" <<'SH'
#!/bin/sh
trap 'sleep 1; if [ -d "$1" ]; then echo kept; else echo gone; fi > "$2.end"; exit 0' TERM
mkdir -p "$1" && echo $$ > "$1/pid"
sleep 300 &
echo $! > "$2"
wait
SH
start_run() { # start_run <cwd> <lock dir> <child pid file> [job]: the fake job in its own session, not our child
  (cd "$1" && python3 -I -c 'import os, sys
if os.fork(): sys.exit(0)
os.setsid(); os.execv(sys.argv[1], sys.argv[1:])' /bin/sh "${4:-$fake_job}" "$2" "$3" < /dev/null > /dev/null 2>&1)
  tries=0; while [ ! -s "$3" ] && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$((tries + 1)); done
}
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
start_run "$demo/console-demo" "$demo/console-demo/.flow/log/next.lock" "$work/run-child"
run_pid="$(cat "$demo/console-demo/.flow/log/next.lock/pid" 2>/dev/null)"; run_child="$(cat "$work/run-child" 2>/dev/null)"
# The same job, its pid in the demo's locks, but working outside the demo: never the demo's to stop.
mkdir -p "$work/elsewhere"
start_run "$work/elsewhere" "$demo/console-demo/.flow/log/next-2.lock" "$work/other-child"
other_pid="$(cat "$demo/console-demo/.flow/log/next-2.lock/pid" 2>/dev/null)"; other_child="$(cat "$work/other-child" 2>/dev/null)"
start_run "$demo/console-demo" "$demo/console-demo/.flow/log/slow.lock" "$work/slow-child" "$slow_job"
slow_pid="$(cat "$demo/console-demo/.flow/log/slow.lock/pid" 2>/dev/null)"
check "the detached run is going before the re-run" alive "$run_pid"
check "the run that outlasts SIGTERM is going before the re-run" alive "$slow_pid"
run_demo --dir "$demo"; code=$?
check "a re-run with a detached run going succeeds" [ "$code" -eq 0 ]
check "a re-run stops a detached run the demo's console started" sh -c "[ -n '$run_pid' ] && ! kill -0 '$run_pid' 2>/dev/null"
check "a re-run stops that run's whole process group" sh -c "[ -n '$run_child' ] && ! kill -0 '$run_child' 2>/dev/null"
tries=0; while [ ! -s "$work/slow-child.end" ] && [ "$tries" -lt 50 ]; do sleep 0.1; tries=$((tries + 1)); done
check "a re-run deletes the demo only after a run that outlasts SIGTERM has ended" [ "$(cat "$work/slow-child.end" 2>/dev/null)" = kept ]
check "a re-run leaves a job working outside the demo alone, though a demo lock names it" alive "$other_pid"
check "a re-run leaves that job's process group alone" alive "$other_child"
for g in "$run_pid" "$other_pid" "$slow_pid"; do alive "$g" && kill -s TERM -- "-$g" 2>/dev/null; done
foreign="$work/foreign"; mkdir -p "$foreign"; : > "$foreign/keep"
run_demo --dir "$foreign"; code=$?
check "a folder the demo did not build is refused" [ "$code" -eq "$usage_exit" ]
check "a folder the demo did not build keeps its files" test -f "$foreign/keep"
run_demo --dir "$work/demo-port" --port "$(sed -n 's/^REAL_CONSOLE_PORT=//p' "$P/scripts/demo.sh")"; code=$?
check "the real console's port is refused" [ "$code" -eq "$usage_exit" ]
check "a refused port builds no demo folder" [ ! -e "$work/demo-port" ]

repo="$(cd "$P/../.." && pwd)"
script_path="$(sed -n 's/^.*`\(plugins\/console\/scripts\/[a-z]*\.sh\)`.*$/\1/p' "$repo/AGENTS.md" | head -n 1)"
check "AGENTS.md names the demo script by its path in the repo" [ "$script_path" = plugins/console/scripts/demo.sh ]
check "the script AGENTS.md names exists and is executable" test -x "$repo/$script_path"

# The real daemon on the demo: needs the app's dev dependencies, as tools/test.sh does.
if [ -d "$P/app/node_modules" ] && command -v curl >/dev/null 2>&1; then
  echo "demo.sh with the real daemon"
  POLL_SECONDS=0.5
  START_POLLS=120
  STOP_POLLS=60
  SHUTDOWN_POLLS=20
  CURL_SECONDS=2
  live="$work/live"; live_home="$work/live-home"; mkdir -p "$live_home"
  live_port="$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
  first=""; second=""; first_daemon=""; second_daemon=""
  start_live() { # start_live <log>: demo.sh in the background, as a caller with its own home
    env -i HOME="$live_home" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" BRAIN_CONSOLE_PROJECTS="$project" \
      sh "$P/scripts/demo.sh" --dir "$live" --port "$live_port" > "$1" 2>&1 &
  }
  poll_until() ( # poll_until <tries> <command...>: succeeds once the command does, fails after <tries> tries
    tries="$1"; shift
    attempt=0
    while [ "$attempt" -lt "$tries" ]; do
      "$@" && exit 0
      sleep "$POLL_SECONDS"; attempt=$((attempt + 1))
    done
    exit 1
  )
  save_healthz() { [ -f "$live/state/token" ] && curl -fsS --max-time "$CURL_SECONDS" -H "Authorization: Bearer $(cat "$live/state/token")" "http://127.0.0.1:$live_port/healthz" > "$work/healthz.json" 2>/dev/null; }
  is_gone() { [ -n "$1" ] && ! kill -0 "$1" 2>/dev/null; } # an unknown pid is never gone, so a check cannot pass on nothing
  port_closed() { ! curl -s --max-time "$CURL_SECONDS" "http://127.0.0.1:$live_port/healthz" > /dev/null; }
  daemon_pid() { node -p 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).pid' "$live/state/daemon.pid" 2>/dev/null; }
  stop_live() { # both demo runs, both daemons they started and the one the pid file names now
    kill $first $second $first_daemon $second_daemon $(daemon_pid) 2>/dev/null
  }
  trap 'stop_live; rm -rf "$work"' EXIT
  trap 'exit 1' INT TERM
  start_live "$work/live-1.log"; first=$!
  poll_until "$START_POLLS" save_healthz; up=$?
  first_daemon="$(daemon_pid)"
  check "the demo's daemon answers on the demo's port" [ "$up" -eq 0 ]
  check "the demo's daemon watches exactly one project" python3 -c "import json, sys; sys.exit(len(json.load(open(sys.argv[1]))['projects']) != 1)" "$work/healthz.json"
  check "the demo's daemon keeps its state in the demo folder" test -f "$live/state/daemon.pid"
  check "the caller's home is left empty by the demo and its daemon" [ -z "$(ls -A "$live_home")" ]
  start_live "$work/live-2.log"; second=$!
  # The daemon, not the demo.sh shell that started it: killing only the shell would orphan it.
  poll_until "$STOP_POLLS" is_gone "$first_daemon"; stopped=$?
  check "a re-run stops the daemon the previous run started" [ "$stopped" -eq 0 ]
  poll_until "$START_POLLS" save_healthz; up=$?
  second_daemon="$(daemon_pid)"
  check "the re-run's daemon answers on the same port" [ "$up" -eq 0 ]
  stop_live
  wait "$second" 2>/dev/null
  check "no demo daemon is left running after the tests" poll_until "$SHUTDOWN_POLLS" port_closed
else
  echo "demo.sh with the real daemon: app dependencies or curl missing, skipping"
fi

echo "console tests: $fails failure(s)"
[ "$fails" -eq 0 ]
