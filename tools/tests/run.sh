#!/bin/sh
# Tests for the repo tools: lint catches a broken plugin. Exit 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

echo "lint on a broken plugin"
out="$work/lint.out"
python3 "$root/tools/lib/check_plugins.py" "$here/fixtures/broken" > "$out"; code=$?
check "fails" [ "$code" -eq 1 ]
check "a missing hook script" grep -q 'hook script missing: .*missing.sh' "$out"
check "a hook script that is not executable" grep -q 'hook script not executable: .*not-executable.sh' "$out"
check "a hook command outside the plugin" grep -q 'hook command does not name a script in the plugin: .*echo outside' "$out"
check "a missing path in an installer" grep -q 'init.sh names a missing plugin path: templates/missing.yaml' "$out"
check "a missing path under CLAUDE_PLUGIN_ROOT" grep -q 'SKILL.md names a missing plugin path: scripts/gone.sh' "$out"
check "nothing else" [ "$(wc -l < "$out" | tr -d ' ')" -eq 5 ]
check "passes on the marketplace" python3 "$root/tools/lib/check_plugins.py" "$root"

[ "$fails" -eq 0 ] && echo "tools: ok"
exit $(( fails > 0 ))
