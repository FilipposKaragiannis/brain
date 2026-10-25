#!/bin/sh
# Comments job: address review comments on every open PR, or one.
#   jobs/comments.sh <claude|codex> [pr|item]
# Finds every open item with a linked PR across the adapters, drops the merged and closed
# ones, and runs the flow `comments` skill once per PR in a fresh host session from the main
# worktree (the skill spawns the comment-addresser in the task's worktree). Before that, with no
# model: a reviewer silent past reviews.chase_after is asked again (comments.sh chase), and a PR
# that conflicts with its base is named in the brief so the skill merges the base in first.
# A PR whose activity (last update, head commit, mergeable, unresolved threads and their
# comments) matches the last pass's is skipped with no model, unless an unresolved thread's last
# comment is not ours: that thread waits on a pass, so it always runs. A named PR always runs. A
# pass's own replies count as activity, so one quiet pass follows each working one. A pass the
# host cut short (a non-zero exit, a timeout, or the host stopping the addresser at its
# background-task ceiling) is failed: its activity is not kept, the next run tries it again, and
# the job exits 1. Nothing open or nothing new: a quiet exit, no model spend.
# Cheap when quiet, so it can run every 5 or 10 minutes; the lock skips an overlap.
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
# activity <target>: one line that changes when anything lands on the PR, read after the chase,
# and in $awaiting the unresolved threads whose last comment is not ours.
activity() {
  awaiting=0
  case "$1" in *#*|local:*) pull="$(json_get "$(adapter read "$1" 2>/dev/null)" state.pr)" ;; *) pull="$1" ;; esac
  [ -n "$pull" ] && act="$("$FLOW_PLUGIN/scripts/comments.sh" activity "$pull" 2>/dev/null)" || return 0
  awaiting="$(json_get "$act" awaiting)"
  printf '%s %s %s threads:%s comments:%s' "$(json_get "$act" updatedAt)" "$(json_get "$act" headRefOid)" "$(json_get "$act" mergeable)" \
    "$(json_get "$act" unresolved)" "$(json_get "$act" review_comments)"
}
# cut_short <output file>: the host's words when it stopped the pass's background work (Claude
# prints this when a subagent outlives its ceiling after the last turn), or nothing.
CUT_SHORT='Background tasks still running .*stopping them'
cut_short() { grep -m1 -E "$CUT_SHORT" "$1" 2>/dev/null; }
seen_file() { printf '%s/%s.seen/%s' "$(job_log_dir)" "$job" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"; }
addressed=0; unchanged=0; failed=""
out="$(job_log_dir)/$job.out.$$"
for t in $targets; do
  note="$(prepare_pr "$t")"
  activity "$t" > "$out"; seen="$(cat "$out")"
  if [ -z "$one" ] && [ -n "$seen" ] && [ "$seen" = "$(cat "$(seen_file "$t")" 2>/dev/null)" ]; then
    if [ "${awaiting:-0}" -eq 0 ] 2>/dev/null; then
      job_say "$t: nothing new since the last pass, skipped" >/dev/null; unchanged=$((unchanged + 1)); continue
    fi
    job_say "$t: $awaiting open thread(s) still wait on a reply" >/dev/null
  fi
  job_say "addressing $t"
  host_run "$host" "$main" "$(host_skill_prompt "$host" flow comments "$t.$note Unattended: nobody answers questions; collect owner decisions in the report and stop.")" "$(job_model)" "$(job_effort)" \
    > "$out" 2>&1
  code=$?
  cat "$out" >> "$(job_log_dir)/$job.log"
  why=""
  if [ "$code" -ne 0 ]; then why="host exit $code"
  elif [ -n "$(cut_short "$out")" ]; then why="the host stopped the addresser before it finished"; fi
  if [ -z "$why" ]; then
    [ -z "$seen" ] || { mkdir -p "$(dirname "$(seen_file "$t")")"; printf '%s\n' "$seen" > "$(seen_file "$t")"; }
  else
    rm -f "$(seen_file "$t")"
    job_say "$t: pass failed, $why; the next run tries it again"
    failed="$failed $t"
  fi
  addressed=$((addressed + 1))
done
rm -f "$out"
[ "$addressed" -gt 0 ] || { job_say "quiet: nothing new on $unchanged PR(s)"; exit 0; }
if [ -n "$failed" ]; then
  job_say "failed:$failed cut short or failed, of $addressed PR(s), $unchanged unchanged"; exit 1
fi
job_say "done: $addressed PR(s), $unchanged unchanged"
