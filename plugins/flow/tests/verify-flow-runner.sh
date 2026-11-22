#!/bin/sh
# verify-flow-runner.sh: verify on the local adapter in throwaway repos. A check's output reaches
# the verify log while the check still runs.
# Exit 0 when every check passes, 1 on any failure.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
. "$here/_verify_fixture.sh"

# standards_with_test <name> <command>: commits .standards/config.json with one test command.
standards_with_test() {
  mkdir -p "$worktree/.standards"
  python3 -c 'import json,sys; json.dump({"test": [{"name": sys.argv[2], "command": sys.argv[3]}]}, open(sys.argv[1], "w"))' \
    "$worktree/.standards/config.json" "$1" "$2"
  git -C "$worktree" add .standards/config.json && git -C "$worktree" commit -qm "config"
}

new_item streaming ""
standards_with_test slow "printf '%s-%s\\n' started slow-check; while [ ! -f '$work/release-slow' ] && [ -d '$work' ]; do sleep 0.2; done"
verify >/dev/null 2>&1 &
streaming_verify=$!
until_true 60 'grep -q started-slow-check "$reports/verify.log"'; seen_while_running=$?
: > "$work/release-slow"
wait "$streaming_verify"
check "CheckStillRunning_HasItsOutputInTheLog because a run stopped at its limit must show where it stood" \
  '[ "$seen_while_running" -eq 0 ]'
exit "$((fails > 0))"
