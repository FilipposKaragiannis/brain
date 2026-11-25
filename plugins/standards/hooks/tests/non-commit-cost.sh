#!/bin/sh
# non-commit-cost.sh: a Bash call that is no commit or push costs the hooks almost nothing. Each
# hook runs under an alarm, so a hook that waits on git or reads every gate is killed and fails.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
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

command_gate_count=400
answer_seconds=2
hung_git_seconds=10
non_commit_payload='{"tool_input":{"command":"ls -la"}}'

hook_exit_within_answer_time() { # <hook script> <PATH for the hook>: the hook's exit code, 142 when the alarm killed it
  printf '%s' "$non_commit_payload" |
    env PATH="$2" perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$answer_seconds" "$hooks/$1" >/dev/null 2>&1
  echo $?
}

cd "$work" || exit 1
git init -q -b main repo && cd repo || exit 1
git config user.email t@t && git config user.name t
mkdir -p .standards
python3 - "$command_gate_count" <<'PY'
import json, sys
gates = [{"name": f"build-{index}", "command": "false", "when": ["commit", "push"]} for index in range(int(sys.argv[1]))]
config = {"version": "0.1.0", "languages": [], "build": "true", "protected": [".editorconfig"], "gates": gates}
json.dump(config, open(".standards/config.json", "w"), indent=2)
PY
git add -A && git commit -qm init

echo "non-commit call: the gates hook with command gates only"
code="$(hook_exit_within_answer_time check-gates.sh "$PATH")"
if [ "$code" -eq 0 ]; then
  pass "ManyCommandGatesAndNoForbidGate_NonCommitCallPassesAtOnce: the gates hook answers within $answer_seconds s, because off a commit or push it reads no gate when none forbids a command"
else
  fail "ManyCommandGatesAndNoForbidGate_NonCommitCallPassesAtOnce: exit $code, wanted 0 within $answer_seconds s"
fi

echo "non-commit call: the commit-only hooks with a git that never answers"
mkdir -p "$work/hung-git"
printf '#!/bin/sh\nexec sleep %s\n' "$hung_git_seconds" > "$work/hung-git/git"
chmod +x "$work/hung-git/git"
for hook in check-no-verify.sh check-config.sh check-comments.sh check-format.sh; do
  code="$(hook_exit_within_answer_time "$hook" "$work/hung-git:$PATH")"
  if [ "$code" -eq 0 ]; then
    pass "HungGit_NonCommitCallPassesAtOnce ($hook): the hook answers within $answer_seconds s, because off a commit or push it starts no git and so finds and reads no config"
  else
    fail "HungGit_NonCommitCallPassesAtOnce ($hook): exit $code, wanted 0 within $answer_seconds s"
  fi
done

[ "$fails" -eq 0 ] && echo "non-commit-cost: ok" || { echo "non-commit-cost: $fails failed"; exit 1; }
