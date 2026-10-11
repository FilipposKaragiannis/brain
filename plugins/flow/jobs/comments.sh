#!/bin/sh
# Comments job: address review comments on every open PR, or one.
#   jobs/comments.sh <claude|codex> [pr|item]
# Finds every open item with a linked PR across the adapters, drops the merged and closed
# ones, and runs the flow `comments` skill once per PR in a fresh host session from the main
# worktree (the skill spawns the comment-addresser in the task's worktree). Nothing open: a
# quiet exit, no model spend. Schedule it every 30 minutes; the lock skips an overlap.
set -u
job=comments
. "$(dirname "$0")/_job.sh"
host="${1:-}"; one="${2:-}"
job_start "$host"
command -v gh >/dev/null 2>&1 || die "gh is not installed"
main="$(main_worktree)"; [ -n "$main" ] || main="$(pwd)"
targets=""
if [ -n "$one" ]; then
  targets="$one"
else
  for a in $(adapters_configured); do
    adapter list "$a" 2>/dev/null | python3 -I -c '
import json, sys
for i in json.load(sys.stdin):
    pr = (i.get("state") or {}).get("pr", "")
    if i.get("status") == "open" and pr: print(i["id"], pr)'
  done | while read -r item pr; do
    state="$("$FLOW_PLUGIN/scripts/comments.sh" state "$pr" 2>/dev/null)" || { job_say "$item: cannot read $pr" >/dev/null; continue; }
    if [ "$(json_get "$state" state)" = "OPEN" ]; then echo "$item"; else job_say "$item: $pr is $(json_get "$state" state), skipped" >/dev/null; fi
  done > "$(job_log_dir)/$job.targets"
  targets="$(cat "$(job_log_dir)/$job.targets")"; rm -f "$(job_log_dir)/$job.targets"
fi
[ -n "$targets" ] || { job_say "quiet: no open PR"; exit 0; }
for t in $targets; do
  job_say "addressing $t"
  host_run "$host" "$main" "Invoke the flow plugin's comments skill (Claude: /flow:comments, Codex: \$comments) for $t. Unattended: nobody answers questions; collect owner decisions in the report and stop." "$(job_model)" "$(job_effort)" \
    >> "$(job_log_dir)/$job.log" 2>&1 || job_say "$t: host exit $?"
done
job_say "done: $(printf '%s\n' $targets | wc -l | tr -d ' ') PR(s)"
