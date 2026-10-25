#!/bin/sh
# Tests for the console plugin's installer and `brain-console update`: install.sh runs under a
# fake home with a fake npm that records its calls (and builds a stand-in page), a launchctl
# that says nothing is loaded, and no network. Needs node 24 or newer (the installer refuses an
# older one), else it skips. Run from anywhere. Exit 1 on any failure.
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
  env -i HOME="$home" PATH="$fake:$PATH" SHELL=/bin/zsh TMPDIR="${TMPDIR:-/tmp}" sh "$script" "$@" > "$work/out" 2>&1
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

project="$work/project"; mkdir -p "$project/.flow"; : > "$project/.flow/config.yaml"
run_install "$P/scripts/install.sh" --no-launchd --project "$project"; code=$?
check "--project adds the folder to the settings" sh -c "[ $code -eq 0 ] && grep -q '\"root\": \"$project\"' '$home/.config/brain-console/config.json'"
run_install "$P/scripts/install.sh" --no-launchd --project "$work"; code=$?
check "--project on a folder with no flow fails the install" [ "$code" -eq 1 ]
run_install "$P/scripts/install.sh" --bogus; code=$?
check "an unknown argument exits 2" [ "$code" -eq 2 ]

nobin="$work/nobin"; mkdir -p "$nobin"
if ! PATH="/bin:/usr/bin" command -v node >/dev/null 2>&1; then
  env -i HOME="$home" PATH="/bin:/usr/bin" sh "$P/scripts/install.sh" --no-launchd > "$work/out" 2>&1; code=$?
  check "without node it exits 2 naming what to install" sh -c "[ $code -eq 2 ] && grep -q 'node is missing; install Node 24' '$work/out'"
else
  echo "  skip without node: /usr/bin has a node"
fi
ln -s "$(command -v node)" "$nobin/node"
env -i HOME="$home" PATH="$nobin:/bin:/usr/bin" sh "$P/scripts/install.sh" --no-launchd > "$work/out" 2>&1; code=$?
if PATH="$nobin:/bin:/usr/bin" command -v npm >/dev/null 2>&1; then echo "  skip without npm: /usr/bin has an npm"; else
  check "without npm it exits 2 naming what to install" sh -c "[ $code -eq 2 ] && grep -q 'npm is missing' '$work/out'"
fi

echo "update"
cached 0.9.0 > /dev/null
newest="$(cached 0.10.0)"
mkdir -p "$home/.claude/plugins/cache/brain-plugins/console/0.11.0"   # no install script: not a plugin
env -i HOME="$home" PATH="$fake:$PATH" TMPDIR="${TMPDIR:-/tmp}" "$launcher" update > "$work/out" 2>&1; code=$?
check "update succeeds" [ "$code" -eq 0 ]
check "update installs the newest cached version by number" sh -c "grep -q 'updating from $newest\$' '$work/out' && [ \"\$(readlink '$share/current')\" = 0.10.0 ]"
check "the version installed before is removed" [ ! -e "$share/$version" ]
check "the only version left is the new one" [ "$(ls "$share")" = "0.10.0
current" ]
check "the launcher now runs the new version" [ "$(HOME="$home" PATH="$fake:$PATH" "$launcher" version)" = 0.10.0 ]
check "update leaves launchd alone when no job is loaded" sh -c "! grep -qE 'bootstrap|kickstart' '$work/offline.log'"

echo "console tests: $fails failure(s)"
[ "$fails" -eq 0 ]
