#!/bin/sh
# Comments job: address review comments on every open PR, or one.
#   jobs/comments.sh <claude|codex> [pr|item]
# Finds every open item with a linked PR across the adapters, drops the merged and closed
# ones, and runs the flow `comments` skill once per PR in a fresh host session from the main
# worktree (the skill spawns the comment-addresser in the task's worktree). Before that, with no
# model: a reviewer silent past reviews.chase_after is asked again (comments.sh chase), and a PR
# that conflicts with its base is named in the brief so the skill merges the base in first.
# Nothing open: a quiet exit, no model spend. Schedule it every 30 minutes; the lock skips an overlap.
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
# prepare_pr <target>: chase its silent reviewers (not on a draft, which waits on its quiz) and
# print the brief's note when the PR conflicts with its base. Model free.
prepare_pr() {
  case "$1" in *#*|local:*) pull="$(json_get "$(adapter read "$1" 2>/dev/null)" state.pr)" ;; *) pull="$1" ;; esac
  [ -n "$pull" ] && state="$("$FLOW_PLUGIN/scripts/comments.sh" state "$pull" 2>/dev/null)" || return 0
  [ "$(json_get "$state" isDraft)" = "true" ] || chase_reviewers "$1" "$pull"
  [ "$(json_get "$state" mergeable)" = "CONFLICTING" ] || return 0
  base="$(json_get "$state" baseRefName)"
  case "$base" in ""|*[!A-Za-z0-9._/-]*) job_say "$1: $pull conflicts with a base named oddly, not merged" >/dev/null; return 0 ;; esac
  job_say "$1: $pull conflicts with $base" >/dev/null
  printf ' The PR conflicts with its base %s: run the Conflicts step first.' "$base"
}
chase_reviewers() { # chase_reviewers <target> <pr>
  "$FLOW_PLUGIN/scripts/comments.sh" chase "$2" 2>&1 | while IFS= read -r line; do job_say "$1: $line" >/dev/null; done
}
for t in $targets; do
  note="$(prepare_pr "$t")"
  job_say "addressing $t"
  host_run "$host" "$main" "$(host_skill_prompt "$host" flow comments "$t.$note Unattended: nobody answers questions; collect owner decisions in the report and stop.")" "$(job_model)" "$(job_effort)" \
    >> "$(job_log_dir)/$job.log" 2>&1 || job_say "$t: host exit $?"
done
job_say "done: $(printf '%s\n' $targets | wc -l | tr -d ' ') PR(s)"
