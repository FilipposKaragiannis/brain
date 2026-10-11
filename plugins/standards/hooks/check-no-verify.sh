#!/bin/sh
# Block `git commit --no-verify` (or -n) and `git push --no-verify`. Hooks are the gate; skipping
# them is never the agent's call.
. "$(dirname "$0")/lib.sh"
payload="$(read_payload)"
cmd="$(payload_command "$payload")"
[ -n "$cmd" ] || exit 0
seg="$(git_segment commit "$cmd")"
if [ -n "$seg" ] && commit_has_flag "$seg" "no-verify" "n"; then
  block "no-verify is blocked" "  the commit skips the hooks: $seg
  Drop --no-verify and fix what the hook reports."
fi
seg="$(git_segment push "$cmd")"
if [ -n "$seg" ] && commit_has_flag "$seg" "no-verify" ""; then
  block "no-verify is blocked" "  the push skips the hooks: $seg"
fi
exit 0
