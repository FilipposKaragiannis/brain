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
run_demo() { # run_demo <args...>: under the fake home, with a real-looking project list in the environment
  env -i HOME="$home" PATH="$nodebin:$PATH" TMPDIR="${TMPDIR:-/tmp}" BRAIN_CONSOLE_PROJECTS="$project" \
    sh "$P/scripts/demo.sh" "$@" > "$work/out" 2>&1
}
in_demo() { # in_demo <command...>: in the demo project, with the PATH the daemon was given
  (cd "$demo/console-demo" && env -i HOME="$demo/home" PATH="$(sed -n 's/^PATH=//p' "$work/node.env")" FLOW_PLUGIN="$P/../flow" "$@")
}
gate_kinds() { sed -n 's/^# Gates: //p' "$P/../flow/scripts/gate.sh" | tr -d '.' | tr ',' '\n' | tr -d ' ' | sort; }
run_demo --dir "$demo" --port 7499; code=$?
check "the demo builds" [ "$code" -eq 0 ]
check "the demo project is a git repo with a commit on main" in_demo git rev-parse --verify -q refs/heads/main
check "the demo project has two worktrees besides its own" [ "$(in_demo git worktree list | wc -l | tr -d ' ')" -eq 3 ]
check "the demo project runs on flow's local adapter" sh -c "sed -n '/^adapters:/,/^[a-z]/p' '$demo/console-demo/.flow/config.yaml' | grep -q 'default: local'"
waiting="$(in_demo sh "$P/../flow/scripts/gate.sh" list | cut -f3 | sort)"
check "the demo has gates waiting" [ -n "$waiting" ]
check "one gate of each kind waits" [ "$waiting" = "$(gate_kinds)" ]
check "claude on the daemon's PATH is the demo's stub" [ "$(in_demo sh -c 'command -v claude')" = "$demo/bin/claude" ]
check "codex on the daemon's PATH is the demo's stub" [ "$(in_demo sh -c 'command -v codex')" = "$demo/bin/codex" ]
in_demo "$demo/bin/claude" -p "a prompt" --output-format json > "$work/stub.json"   # by path: a broken PATH must never reach a real claude
check "the stub claude reports no tokens spent" python3 -c "import json, sys; usage = json.load(open(sys.argv[1]))['usage']; sys.exit(sum(usage.values()) != 0)" "$work/stub.json"
check "the stub claude logs each call" grep -q 'claude -p a prompt' "$demo/agents.log"
check "the daemon starts on the demo project, port, state dir and config only" [ "$(cat "$work/node.args")" = "$P/app/daemon/src/main.ts
start
--project
$demo/console-demo
--port
7499
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
foreign="$work/foreign"; mkdir -p "$foreign"; : > "$foreign/keep"
run_demo --dir "$foreign"; code=$?
check "a folder the demo did not build is refused" [ "$code" -eq 2 ]
check "a folder the demo did not build keeps its files" test -f "$foreign/keep"
run_demo --dir "$work/demo-port" --port "$(sed -n 's/^REAL_CONSOLE_PORT=//p' "$P/scripts/demo.sh")"; code=$?
check "the real console's port is refused" [ "$code" -eq 2 ]
check "a refused port builds no demo folder" [ ! -e "$work/demo-port" ]

repo="$(cd "$P/../.." && pwd)"
script_path="$(sed -n 's/^.*`\(plugins\/console\/scripts\/[a-z]*\.sh\)`.*$/\1/p' "$repo/AGENTS.md" | head -n 1)"
check "AGENTS.md names the demo script by its path in the repo" [ "$script_path" = plugins/console/scripts/demo.sh ]
check "the script AGENTS.md names exists and runs" test -x "$repo/$script_path"

# The real daemon on the demo: needs the app's dev dependencies, as tools/test.sh does.
if [ -d "$P/app/node_modules" ] && command -v curl >/dev/null 2>&1; then
  echo "demo.sh with the real daemon"
  live="$work/live"; live_home="$work/live-home"; mkdir -p "$live_home"
  live_port="$(node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})')"
  start_live() { # start_live <log>: demo.sh in the background, as a caller with its own home
    env -i HOME="$live_home" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" BRAIN_CONSOLE_PROJECTS="$project" \
      sh "$P/scripts/demo.sh" --dir "$live" --port "$live_port" > "$1" 2>&1 &
  }
  healthz() { [ -f "$live/state/token" ] && curl -fsS --max-time 2 -H "Authorization: Bearer $(cat "$live/state/token")" "http://127.0.0.1:$live_port/healthz" 2>/dev/null; }
  wait_healthz() { i=0; while [ $i -lt 120 ]; do healthz > "$work/healthz.json" && return 0; sleep 0.5; i=$((i + 1)); done; return 1; }
  stop_live() { # the daemon a demo run left: its pid is in the JSON pid file
    [ -f "$live/state/daemon.pid" ] && kill "$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).pid' "$live/state/daemon.pid")" 2>/dev/null
  }
  trap 'stop_live; rm -rf "$work"' EXIT
  gone() { i=0; while [ $i -lt 60 ]; do kill -0 "$1" 2>/dev/null || return 0; sleep 0.5; i=$((i + 1)); done; return 1; }
  start_live "$work/live-1.log"; first=$!
  wait_healthz; up=$?
  check "the demo's daemon answers on the demo's port" [ "$up" -eq 0 ]
  check "the demo's daemon watches exactly one project" python3 -c "import json, sys; sys.exit(len(json.load(open(sys.argv[1]))['projects']) != 1)" "$work/healthz.json"
  check "the demo's daemon keeps its state in the demo folder" test -f "$live/state/daemon.pid"
  check "the caller's home is left empty by the demo and its daemon" [ -z "$(ls -A "$live_home")" ]
  start_live "$work/live-2.log"; second=$!
  gone "$first"; stopped=$?
  check "a re-run stops the daemon the previous run started" [ "$stopped" -eq 0 ]
  wait_healthz; up=$?
  check "the re-run's daemon answers on the same port" [ "$up" -eq 0 ]
  stop_live
  { kill "$first" "$second"; wait "$second"; } 2>/dev/null
  i=0; while [ $i -lt 20 ] && curl -s --max-time 1 "http://127.0.0.1:$live_port/healthz" >/dev/null; do sleep 0.5; i=$((i + 1)); done
  check "no demo daemon is left running after the tests" sh -c "! curl -sS --max-time 2 'http://127.0.0.1:$live_port/healthz'"
else
  echo "demo.sh with the real daemon: app dependencies or curl missing, skipping"
fi

echo "console tests: $fails failure(s)"
[ "$fails" -eq 0 ]
