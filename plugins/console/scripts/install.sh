#!/bin/sh
# Put the Brain Console on this machine and start it on login.
#   install.sh [--no-launchd] [--project <root>]...
# Copies the app beside this script (../app, without node_modules or ui/dist) to
# <home>/.local/share/brain-console/<version>/, runs npm ci and the UI build there, points
# <home>/.local/share/brain-console/current at it, writes the launcher <home>/.local/bin/brain-console,
# adds each --project to the console's settings, runs `brain-console install` (launchd) unless
# --no-launchd, and prints `brain-console status`. The versions other than the new one are removed
# once every step worked. <home> is BRAIN_CONSOLE_HOME, else HOME.
# Exit 2 when node or npm is missing or an argument is wrong, 1 when a step fails.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
app="$(cd "$here/../app" 2>/dev/null && pwd)" || { echo "console install: no app folder beside $here" >&2; exit 1; }
home="${BRAIN_CONSOLE_HOME:-$HOME}"
launchd=1
expect_root=0
for arg in "$@"; do
  if [ "$expect_root" -eq 1 ]; then expect_root=0; continue; fi
  case "$arg" in
    --no-launchd) launchd=0 ;;
    --project) expect_root=1 ;;
    *) echo "console install: unknown argument $arg (use --no-launchd, --project <root>)" >&2; exit 2 ;;
  esac
done
[ "$expect_root" -eq 0 ] || { echo "console install: --project needs a folder" >&2; exit 2; }

command -v node >/dev/null 2>&1 || { echo "console install: node is missing; install Node 24 or newer (https://nodejs.org, or: brew install node), then run this again" >&2; exit 2; }
command -v npm >/dev/null 2>&1 || { echo "console install: npm is missing; it comes with Node 24 or newer (https://nodejs.org, or: brew install node)" >&2; exit 2; }
major="$(node -p 'process.versions.node.split(".")[0]')"
[ "$major" -ge 24 ] 2>/dev/null || { echo "console install: node $(node --version) is too old; install Node 24 or newer" >&2; exit 2; }
version="$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).version' "$app/package.json")"
[ -n "$version" ] || { echo "console install: no version in $app/package.json" >&2; exit 1; }

share="$home/.local/share/brain-console"
target="$share/$version"
staging="$share/.install-$version-$$"
bin="$home/.local/bin"
launcher="$bin/brain-console"
fail() { echo "console install: $1" >&2; rm -rf "$staging"; exit 1; }

echo "console install: $version from $app into $target"
mkdir -p "$staging" || fail "cannot create $staging"
# A plugin copied from a local checkout may carry node_modules and a build: never copy them.
(cd "$app" && tar -cf - --exclude node_modules --exclude dist .) | (cd "$staging" && tar -xf -) || fail "cannot copy $app"
(cd "$staging" && npm ci --no-audit --no-fund) || fail "npm ci failed in $staging"
(cd "$staging" && npm --prefix ui ci --no-audit --no-fund && npm --prefix ui run build) || fail "the UI build failed in $staging/ui"
rm -rf "$target" && mv "$staging" "$target" || fail "cannot move the new copy to $target"
ln -sfn "$version" "$share/current" || fail "cannot point $share/current at $version"

mkdir -p "$bin" || fail "cannot create $bin"
if [ "$home" = "${HOME:-}" ]; then entry='$HOME/.local/share/brain-console/current/daemon/src/main.ts'; else entry="$share/current/daemon/src/main.ts"; fi
printf '#!/bin/sh\nexec node "%s" "$@"\n' "$entry" > "$launcher.tmp" && chmod 755 "$launcher.tmp" && mv "$launcher.tmp" "$launcher" || fail "cannot write $launcher"
echo "console install: wrote $launcher"
case ":${PATH:-}:" in
  *":$bin:"*) ;;
  *)
    case "${SHELL:-}" in */zsh) profile="~/.zshrc" ;; */bash) profile="~/.bash_profile" ;; *) profile="~/.profile" ;; esac
    echo "console install: $bin is not on your PATH; add this line to $profile and open a new terminal:"
    echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    ;;
esac

expect_root=0
for arg in "$@"; do
  if [ "$expect_root" -eq 1 ]; then expect_root=0; "$launcher" add "$arg" || fail "could not add $arg"; continue; fi
  [ "$arg" = --project ] && expect_root=1
done

status=0
if [ "$launchd" -eq 1 ]; then
  "$launcher" install || { status=1; echo "console install: the files are in place, but the launch agent did not start (above); fix that, then run: brain-console install" >&2; }
fi
if [ "$status" -eq 0 ]; then
  for old in "$share"/*/; do
    name="$(basename "$old")"
    [ "$name" = "$version" ] || [ "$name" = current ] || { rm -rf "${old%/}" && echo "console install: removed $name"; }
  done
fi
"$launcher" status
exit $status
