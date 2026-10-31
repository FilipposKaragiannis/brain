#!/bin/sh
# Comments job: address review comments on every open PR, or one.
#   jobs/comments.sh <claude|codex> [pr|item]
# Finds every open item with a linked PR across the adapters, drops the merged and closed
# ones, and runs the flow `comments` skill once per PR in a fresh host session from the main
# worktree (the skill spawns the comment-addresser in the task's worktree). Before that, with no
# model: a reviewer silent past reviews.chase_after is asked again (comments.sh chase), and a PR
# that conflicts with its base is named in the brief so the skill merges the base in first.
# An item waiting at a gate other than merge is skipped, and so is an item whose worktree another
# session works in (the health job's process scan), named or not: the pass would edit under it.
# A PR whose activity (last update, head commit, mergeable, unresolved threads, their comments,
# the threads whose last word is not the flow's reply, and the time the item's last gate was
# cleared) matches the last pass's is skipped with no model. Threads still waiting on a
# reply get one more pass, then the owner is told once. A named PR always runs. A pass's own
# replies count as activity, so one quiet pass follows each working one. A pass the host cut short
# (a non-zero exit, or the host stopping the addresser at its background-task ceiling) is failed:
# its activity is not kept, the next run tries it again, and the job exits 1; after
# jobs.comments.max_failures (3) in a row the job stops trying the PR and the owner is told
# once, until a pass run by hand completes. Nothing open or nothing new: a quiet exit, no model spend.
# Cheap when quiet, so it can run every 5 or 10 minutes; the lock skips an overlap.
set -u
job=comments
. "$(dirname "$0")/_job.sh"
host="${1:-}"; one="${2:-}"
job_start "$host" model
out="$(job_log_dir)/$job.out.$$"
trap 'c=$?; rm -f "$out" "$out.code" "$out.login" "$out.procs" "$out.procs.failed"; job_end $c' EXIT
(unset -f gh; command -v gh >/dev/null 2>&1) || die "gh is not installed"
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
    if i.get("status") == "open" and pr: print(i["id"], pr, (i.get("state") or {}).get("gate") or "none")'
  done | while read -r item pr gate; do
    # A gate other than merge is the owner's to answer first: a pass would stop at it again.
    case "$gate" in none|merge) ;; *) job_say "$item: waits at the $gate gate, skipped" >/dev/null; continue ;; esac
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
# activity <target>: one line that changes when anything lands on the PR, read after the chase.
# $awaiting holds the last comment ids of the unresolved threads whose last word is not the
# flow's reply, space separated, and they are part of the line. So is the time the item's last
# gate was cleared (gate.sh clear), once one was: a pass that stopped at a gate left the PR as it
# was, and the owner's answer is what is new. A line with no clear is the line before 1.23.0.
activity() {
  awaiting=""; cleared=""
  case "$1" in
    *#*|local:*) data="$(adapter read "$1" 2>/dev/null)"; pull="$(json_get "$data" state.pr)"; cleared="$(json_get "$data" state.answered_at)" ;;
    *) pull="$1" ;;
  esac
  [ -n "$pull" ] && act="$("$FLOW_PLUGIN/scripts/comments.sh" activity "$pull" 2>/dev/null)" || return 0
  awaiting="$(json_list "$act" awaiting | tr '\n' ' ' | sed 's/ $//')"
  printf '%s %s %s threads:%s comments:%s awaiting:%s%s' "$(json_get "$act" updatedAt)" "$(json_get "$act" headRefOid)" "$(json_get "$act" mergeable)" \
    "$(json_get "$act" unresolved)" "$(json_get "$act" review_comments)" "$(printf '%s' "$awaiting" | tr ' ' ',')" "${cleared:+ cleared:$cleared}"
}
# cut_short <output file>: the host's own line when it stopped the pass's background work (Claude
# prints it when a subagent outlives its ceiling after the last turn), or nothing. Only a line that
# opens with it, near the end of the output, counts: the model's text may quote it.
CUT_SHORT='^Background tasks still running .*; stopping them\.'
cut_short() { tail -n 20 "$1" 2>/dev/null | grep -m1 -E "$CUT_SHORT"; }
# Per PR, beside the last good pass's activity (<pr>): <pr>.forced, the awaiting set a pass was
# forced for; <pr>.fails, the count of failed passes in a row, whatever they changed (a pass cut
# short after one reply changes the activity each time), cleared only by a pass that completes;
# <pr>.told and
# <pr>.told-fails, what the owner was last told. Each is said once.
seen_file() { printf '%s/%s.seen/%s' "$(job_log_dir)" "$job" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"; }
max_fails="$(cfg_or jobs.comments.max_failures 3)"
case "$max_fails" in ''|*[!0-9]*) die "jobs.comments.max_failures takes a whole number" 2 ;; esac
tell() { "$FLOW_PLUGIN/scripts/notify.sh" --event comments "$1" >/dev/null 2>&1 || true; }
# item_of <target>: the item a target names: the target itself, or for a PR number the item its
# branch names, flow/<item slug> (flow/gh-12 is gh#12, flow/local-task-1 is local:task/1);
# nothing for a PR the flow did not open.
item_of() {
  case "$1" in *#*|local:*) printf '%s' "$1" ;;
    *) "$FLOW_PLUGIN/scripts/comments.sh" state "$1" 2>/dev/null | python3 -I -c '
import json, re, sys
head = json.load(sys.stdin).get("headRefName", "")
gh, local = re.match(r"flow/gh-(\d+)$", head), re.match(r"flow/local-([a-z]+)-(\d+)$", head)
print("gh#" + gh.group(1) if gh else "local:%s/%s" % local.groups() if local else "")' 2>/dev/null ;;
  esac
}
# resume_note <target>: the item's comments-resume.md, the note a cut-short pass leaves for the
# next one (the shape of the health job's resume.md), in the reports folder the steward names.
resume_note() {
  rn_item="$(item_of "$1")"
  [ -n "$rn_item" ] || return 1
  rn_dir="$("$FLOW_PLUGIN/scripts/steward.sh" reports "$rn_item" 2>/dev/null)" || return 1
  printf '%s/comments-resume.md' "$rn_dir"
}
# claimed_by <worktree> <item>: the worktree's claim names the item, so its changes are this
# item's. A released item's reports can sit in a pool worktree another item now holds.
claimed_by() { [ "$(json_get "$(cat "$1/.flow/claim.json" 2>/dev/null)" item)" = "$2" ]; }
# dirty_tree <worktree>: uncommitted changes outside .flow.
dirty_tree() { [ -n "$(git -C "$1" status --porcelain -- . ':!.flow' 2>/dev/null)" ]; }
# The flow's GitHub login, read at most once per run and only when a thread lacks the reply
# marker (a reply from before 1.19.0): comments.sh activity reads this cache.
FLOW_GH_LOGIN_CACHE="$out.login"; export FLOW_GH_LOGIN_CACHE
# in_use <target>: sets $in_use_why to why another session may be working in the worktree the
# item holds, or to nothing. Not run in a subshell: the processes are listed once per run, the
# first time a target holds a worktree (FLOW_HEALTH_PROCS names a list, as for the health job).
# When they cannot be listed, every worktree counts as in use, as the steward counts it.
in_use() {
  in_use_why=""
  iu_item="$(item_of "$1")"; [ -n "$iu_item" ] || return 0
  iu_wt="$("$FLOW_PLUGIN/scripts/steward.sh" find "$iu_item" 2>/dev/null)"; [ -n "$iu_wt" ] || return 0
  if [ -z "$procs" ]; then
    procs="${FLOW_HEALTH_PROCS:-}"
    [ -n "$procs" ] || { procs="$out.procs"; python3 -I "$FLOW_PLUGIN/scripts/_health.py" procs > "$procs" 2>/dev/null || : > "$procs.failed"; }
  fi
  if [ -f "$procs.failed" ]; then in_use_why="the processes cannot be listed, so a session may be working in $iu_wt"; return 0; fi
  iu_how="$(python3 -I "$FLOW_PLUGIN/scripts/_health.py" alive "$procs" "$iu_item" "$iu_wt" "" 2>/dev/null)"
  [ -z "$iu_how" ] || in_use_why="another session works in $iu_wt ($iu_how)"
}
# once <file> <value>: true the first time <value> is seen for <file>, and records it.
once() { [ "$(cat "$1" 2>/dev/null)" != "$2" ] && printf '%s\n' "$2" > "$1"; }
addressed=0; unchanged=0; busy=0; failed=""; procs=""
for t in $targets; do
  in_use "$t"
  if [ -n "$in_use_why" ]; then job_say "$t: $in_use_why, skipped" >/dev/null; busy=$((busy + 1)); continue; fi
  note="$(prepare_pr "$t")"
  activity "$t" > "$out"; seen="$(cat "$out")"; f="$(seen_file "$t")"; mkdir -p "$(dirname "$f")"
  fails=0
  [ -f "$f.fails" ] && { read -r fails _ < "$f.fails"; case "$fails" in ''|*[!0-9]*) fails=0 ;; esac; }
  if [ -z "$one" ] && [ "$fails" -ge "$max_fails" ]; then
    job_say "$t: $fails passes in a row failed, skipped until a pass run by hand completes" >/dev/null
    once "$f.told-fails" "$fails" && tell "$t: the comments pass failed $fails times in a row on $pull, so the job stops trying it. Read $(job_log_dir)/$job.log, then run it by hand: jobs/comments.sh <host> $t. A pass that completes lets the job try it again."
    unchanged=$((unchanged + 1)); continue
  fi
  if [ -z "$one" ] && [ -n "$seen" ] && [ "$seen" = "$(cat "$f" 2>/dev/null)" ]; then
    if [ -z "$awaiting" ]; then
      job_say "$t: nothing new since the last pass, skipped" >/dev/null; unchanged=$((unchanged + 1)); continue
    fi
    if [ "$(cat "$f.forced" 2>/dev/null)" = "$awaiting" ]; then
      job_say "$t: open thread(s) $awaiting still wait on a reply after a pass, skipped" >/dev/null
      once "$f.told" "$awaiting" && tell "$t: review thread(s) on $pull still wait on a reply after two passes (last comments $awaiting). Answer them, or run the pass by hand: jobs/comments.sh <host> $t."
      unchanged=$((unchanged + 1)); continue
    fi
    printf '%s\n' "$awaiting" > "$f.forced"
    job_say "$t: open thread(s) $awaiting still wait on a reply, one more pass" >/dev/null
  fi
  rn_item=""; resume=""; rnote=""; resume_note "$t" > "$out" && resume="$(cat "$out")"
  # Uncommitted changes in the claimed worktree with no note: a run before this one was cut off
  # (before flow 1.19.0 no note was left). Say so, so the pass continues from them.
  if [ -n "$resume" ] && [ ! -s "$resume" ]; then
    rwt="${resume%/.flow/reports/*}"
    if [ -d "$rwt" ] && claimed_by "$rwt" "$rn_item" && dirty_tree "$rwt"; then
      printf 'An earlier run on PR #%s left uncommitted changes in %s (found by the comments job at %s). Read git status and git diff, continue from there, build and test before you commit, discard nothing without saying so in the reply.\n' \
        "${pull##*/}" "$rwt" "$(now_iso)" > "$resume"
      job_say "$t: $rwt holds uncommitted changes from an earlier run; the pass continues from them" >/dev/null
    fi
  fi
  [ -z "$resume" ] || [ ! -s "$resume" ] || rnote=" An earlier pass was cut short: read $resume first and continue from its work."
  job_say "addressing $t"
  # The output goes to the log as it comes, so a pass killed half way keeps what it said.
  { job_host_run "$main" "$(host_skill_prompt "$host" flow comments "$t.$note$rnote Unattended: nobody answers questions; collect owner decisions in the report and stop.")" 2>&1
    echo $? > "$out.code"; } | tee -a "$(job_log_dir)/$job.log" > "$out"
  code="$(cat "$out.code" 2>/dev/null)"; code="${code:-1}"
  why=""
  if [ "$code" -ne 0 ]; then why="host exit $code"
  elif [ -n "$(cut_short "$out")" ]; then why="the host stopped the addresser before it finished"; fi
  if [ -z "$why" ]; then
    [ -z "$seen" ] || printf '%s\n' "$seen" > "$f"
    rm -f "$f.fails" "$f.told-fails"
    # The note goes once the work it names is gone from the tree: an addresser that stopped
    # cleanly on a failing build leaves the changes, and the note stays for the next pass.
    if [ -n "$resume" ]; then
      rwt="${resume%/.flow/reports/*}"
      { claimed_by "$rwt" "$rn_item" && dirty_tree "$rwt"; } || rm -f "$resume"
    fi
  else
    rm -f "$f"
    printf '%s %s\n' "$((fails + 1))" "$seen" > "$f.fails"
    job_say "$t: pass failed, $why; the next run tries it again"
    if [ -n "$resume" ]; then
      rwt="${resume%/.flow/reports/*}"
      printf 'The previous comments pass on PR #%s was cut short at %s (%s). %s may hold its uncommitted work. Read git status and git diff, continue from there, build and test before you commit, discard nothing without saying so in the reply.\n' \
        "${pull##*/}" "$(now_iso)" "$why" "$rwt" > "$resume"
    fi
    failed="$failed $t"
  fi
  addressed=$((addressed + 1))
done
in_use_said=""; [ "$busy" -eq 0 ] || in_use_said=", $busy in use by another session"
[ "$addressed" -gt 0 ] || { job_say "quiet: nothing new on $unchanged PR(s)$in_use_said"; exit 0; }
if [ -n "$failed" ]; then
  job_say "failed:$failed cut short or failed, of $addressed PR(s), $unchanged unchanged$in_use_said"; exit 1
fi
job_say "done: $addressed PR(s), $unchanged unchanged$in_use_said"
