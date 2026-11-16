#!/bin/sh
# gate-git-env.sh: a command gate runs without git's repository variables. A git hook exports
# GIT_DIR and its siblings, and a gate that inherits them aims its tests' git at the repository
# being committed. The gate leaves a marker only when it saw none of them, so a gate that never
# ran fails too. Exit 0 when every check passes, 1 on any failure. run.sh runs it.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
hooks="$here/.."
work="$(mktemp -d)"
. "$hooks/../../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$hooks/.."
trap 'sandbox_close $?' EXIT
mkdir -p "$work/offline"
for tool in curl wget gh osascript notify-send claude codex; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/offline.log"\n' "$tool" "$work" > "$work/offline/$tool"
  chmod +x "$work/offline/$tool"
done
PATH="$work/offline:$PATH"; export PATH
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

cd "$work"
git init -q -b main repo && cd repo
git config user.email t@t && git config user.name t
mkdir -p .standards
cat > .standards/config.json <<JSON
{
  "version": "0.1.0",
  "languages": [],
  "build": "true",
  "protected": [],
  "gates": [{"name": "git-env", "command": "env | grep -E '^GIT_(DIR|INDEX_FILE|WORK_TREE)=' || touch '$work/gate-clean'"}]
}
JSON
git add -A && git commit -qm init

echo "command gates: git's repository variables"
printf '{"tool_input":{"command":"git commit -m x"}}' | env GIT_DIR="$work/repo/.git" GIT_INDEX_FILE="$work/repo/.git/index" \
  GIT_WORK_TREE="$work/repo" "$hooks/check-gates.sh" >/dev/null 2>&1
check "GateFromGitHook_RunsWithoutGitRepositoryVariables: the gate ran and saw no GIT_DIR, GIT_INDEX_FILE or GIT_WORK_TREE" [ -f "$work/gate-clean" ]

[ "$fails" -eq 0 ] && echo "gate-git-env: ok" || { echo "gate-git-env: $fails failed"; exit 1; }
