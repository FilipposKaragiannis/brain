#!/bin/sh
# Put the Brain Console on this machine and start it on login.
#   install.sh [--no-launchd] [--keep-old] [--project <root>]...
# Copies the app beside this script (../app, without node_modules or ui/dist) to
# <home>/.local/share/brain-console/<version>/, runs npm ci and the UI build there, points
# <home>/.local/share/brain-console/current at it, writes the launcher <home>/.local/bin/brain-console,
# adds each --project to the console's settings, runs `brain-console install` (launchd) unless
# --no-launchd, and prints `brain-console status`. The versions other than the new one are removed
# once every step worked, unless --keep-old (brain-console update prunes after its restart). A
# step that fails after current moved points it back at the version before. <home> is
# BRAIN_CONSOLE_HOME, else HOME; the launcher keeps BRAIN_CONSOLE_HOME when it is not HOME.
# Exit 2 when node or npm is missing or an argument is wrong, 1 when a step fails.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
app="$(cd "$here/../app" 2>/dev/null && pwd)" || { echo "console install: no app folder beside $here" >&2; exit 1; }
home="${BRAIN_CONSOLE_HOME:-$HOME}"
launchd=1
keep_old=0
expect_root=0
for arg in "$@"; do
  if [ "$expect_root" -eq 1 ]; then expect_root=0; continue; fi
  case "$arg" in
    --no-launchd) launchd=0 ;;
    --keep-old) keep_old=1 ;;
    --project) expect_root=1 ;;
    *) echo "console install: unknown argument $arg (use --no-launchd, --keep-old, --project <root>)" >&2; exit 2 ;;
  esac
done
[ "$expect_root" -eq 0 ] || { echo "console install: --project needs a folder" >&2; exit 2; }

command -v node >/dev/null 2>&1 || { echo "console install: node is missing; install Node 24 or newer (https://nodejs.org, or: brew install node), then run this again" >&2; exit 2; }
command -v npm >/dev/null 2>&1 || { echo "console install: npm is missing; it comes with Node 24 or newer (https://nodejs.org, or: brew install node)" >&2; exit 2; }
major="$(node -p 'process.versions.node.split(".")[0]')"
[ "$major" -ge 24 ] 2>/dev/null || { echo "console install: node $(node --version) is too old; install Node 24 or newer" >&2; exit 2; }
version="$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).version' "$app/package.json")"
# The version names a folder that is replaced and pruned: only digits and dots.
printf '%s' "$version" | grep -Eq '^[0-9]+(\.[0-9]+)*$' || { echo "console install: $app/package.json has no version of digits and dots (got '$version')" >&2; exit 2; }

share="$home/.local/share/brain-console"
target="$share/$version"
staging="$share/.install-$version-$$"
archive="$share/.install-$version-$$.tar"
aside="$share/.old-$version-$$"
bin="$home/.local/bin"
launcher="$bin/brain-console"
previous=""
fail() { echo "console install: $1" >&2; rm -rf "$staging" "$archive"; exit 1; }
# After current moved: point it back at the version before, say so, and fail.
roll_back() {
  if [ -n "$previous" ] && [ "$previous" != "$version" ] && [ -d "$share/$previous" ]; then
    ln -sfn "$previous" "$share/current" && echo "console install: current points back at $previous" >&2
  fi
  echo "console install: $1" >&2
  exit 1
}

echo "console install: $version from $app into $target"
mkdir -p "$share" || fail "cannot create $share"
# A run killed half way leaves its staging folder, archive or set-aside copy: none is in use.
rm -rf "$share"/.install-* "$share"/.old-*
mkdir -p "$staging" || fail "cannot create $staging"
# A plugin copied from a local checkout may carry node_modules and a build: never copy them.
# Through an archive, so a failed read and a failed write are each caught.
(cd "$app" && tar -cf "$archive" --exclude node_modules --exclude dist .) || fail "cannot read $app"
(cd "$staging" && tar -xf "$archive") || fail "cannot copy $app"
rm -f "$archive"
(cd "$staging" && npm ci --no-audit --no-fund) || fail "npm ci failed in $staging"
(cd "$staging" && npm --prefix ui ci --no-audit --no-fund && npm --prefix ui run build) || fail "the UI build failed in $staging/ui"
# The same version again: the copy in use is moved aside, never deleted before the new one is there.
if [ -e "$target" ]; then mv "$target" "$aside" || fail "cannot move the old $target aside"; fi
if ! mv "$staging" "$target"; then
  [ -e "$aside" ] && mv "$aside" "$target"
  fail "cannot move the new copy to $target"
fi
rm -rf "$aside"
previous="$(readlink "$share/current" 2>/dev/null || true)"
ln -sfn "$version" "$share/current" || fail "cannot point $share/current at $version"

mkdir -p "$bin" || roll_back "cannot create $bin"
if [ "$home" = "${HOME:-}" ]; then
  entry='$HOME/.local/share/brain-console/current/daemon/src/main.ts'
  printf '#!/bin/sh\nexec node "%s" "$@"\n' "$entry" > "$launcher.tmp"
  shown_bin='$HOME/.local/bin'
else
  # Kept, so a later install or update from a plain shell works on this home, not $HOME.
  printf '#!/bin/sh\nBRAIN_CONSOLE_HOME="%s"; export BRAIN_CONSOLE_HOME\nexec node "%s" "$@"\n' "$home" "$share/current/daemon/src/main.ts" > "$launcher.tmp"
  shown_bin="$bin"
fi
chmod 755 "$launcher.tmp" && mv "$launcher.tmp" "$launcher" || roll_back "cannot write $launcher"
echo "console install: wrote $launcher"
case ":${PATH:-}:" in
  *":$bin:"*) ;;
  *)
    case "${SHELL:-}" in */zsh) profile="~/.zshrc" ;; */bash) profile="~/.bash_profile" ;; *) profile="~/.profile" ;; esac
    echo "console install: $bin is not on your PATH; add this line to $profile and open a new terminal:"
    echo "  export PATH=\"$shown_bin:\$PATH\""
    ;;
esac

expect_root=0
for arg in "$@"; do
  if [ "$expect_root" -eq 1 ]; then expect_root=0; "$launcher" add "$arg" || roll_back "could not add $arg"; continue; fi
  [ "$arg" = --project ] && expect_root=1
done

if [ "$launchd" -eq 1 ]; then
  "$launcher" install || roll_back "the launch agent did not start with $version (above); fix that, then run: brain-console install"
fi
if [ "$keep_old" -eq 0 ]; then
  for old in "$share"/*/; do
    name="$(basename "$old")"
    [ "$name" = "$version" ] || [ "$name" = current ] || { rm -rf "${old%/}" && echo "console install: removed $name"; }
  done
fi
"$launcher" status
exit 0
