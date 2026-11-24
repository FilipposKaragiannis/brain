#!/bin/sh
# Comments job: address review comments on every open PR, or one.
#   jobs/comments.sh <claude|codex> [pr|item] [--workers N] [--model <name>] [--effort <level>]
# Finds every open item with a linked PR across the adapters, drops the merged and closed
# ones, and runs the flow `comments` skill once per PR in a fresh host session started in the
# item's worktree, or the main worktree when it holds none (the skill spawns the
# comment-addresser in the task's worktree). Before that, with no
# model: a reviewer of the PR's author host silent past reviews.chase_after is asked again
# (comments.sh chase), a PR that conflicts with its base is named in the brief so the skill
# merges the base in first, and the checks failing on the PR's head are named so it fixes them.
# An owner's answer that waits on this job (answer_pending comments: a gate cleared on an item at
# done) is named in the brief too and always gets a pass. The pass confirms it carried the answer
# out, or raised it again as a gate, by writing the answer's time (answered_at) to the file the
# brief names; only then is the answer taken, and only while that same answer still waits. A pass
# that ends without the confirmation is a failed pass: the answer stays pending.
# An item waiting at a gate other than merge is skipped, and so is an item whose worktree another
# session works in (the health job's process scan), named or not: the pass would edit under it.
# A session a person started that has been idle for jobs.comments.idle_session (30m) holds a
# worktree with nothing uncommitted in it no longer, so an abandoned session stops a PR's
# comments for half an hour, not for days. A pass that waited for a slot checks the worktree
# again before it starts, so a person back in that session keeps it out.
# The owner is told once per PR while it stays in use (event comments-skipped): the item, the PR,
# the worktree and what works there; again only after a pass addressed the PR.
# A PR whose activity (last update, head commit, mergeable, unresolved threads, their comments,
# the threads whose last word is not the flow's reply, the time the item's last gate was
# cleared, and the checks failing on the head) matches the last pass's is skipped with no model.
# A check that goes red on a head gets one pass; one the pass could not fix leaves the line as it
# was, so a flaky or broken check is not tried again until the head changes. Threads still waiting
# on a reply get one more pass, then the owner is told once. A named PR always runs. A pass's own
# replies count as activity, so one quiet pass follows each working one. A pass the host cut short
# (a non-zero exit, or the host stopping the addresser at its background-task ceiling) is failed:
# its activity is not kept, the next run tries it again, and the job exits 1; after
# jobs.comments.max_failures (3) in a row the job stops trying the PR and the owner is told
# once, until a pass run by hand completes. Nothing open or nothing new: a quiet exit, no model spend.
# Cheap when quiet, so it can run every 5 or 10 minutes. Runs overlap: each holds its own
# <schedule>-<pid>.lock, and every schedule of the job shares one seen record per PR under
# comments.seen/. Each pass holds its PR's lock with no wait: the item's
# (<flow home>/item:<item slug>.lock), or pr:<number>.lock for a PR the flow did not open, so no
# two passes work one PR at once: a held one skips the PR, counted in use.
# --workers N, or jobs.comments_workers in .flow/config.yaml, runs up to N passes at once (1 to
# 16), each on its own PR; unset or 1 runs them one after another. jobs.comments_workers also caps
# the passes live at once across all runs, through the slot pool (lib/slots.sh); a run given
# --workers N may use slots up to N. A pass holds a slot for its host session only, until the
# session's process group is gone even when the run is stopped first, and waits for a free one: it
# never skips a PR for lack of a slot. A run that names its PR prints the wait and the runs that
# hold the slots. A pass still running at
# jobs.comments.pass_limit (1h) is stopped with its children and counts as failed, so the next run
# tries it again. The processes are listed once per run.
# The result line names every open PR and what it came to: addressed, nothing new, waits on you
# (threads still unanswered after two passes, or passes failing in a row), in use (the session in
# its worktree and how long it has been idle) or at a gate. A red check never holds a PR back: the
# pass fixes the checks it can, then addresses the threads whatever CI says.
# A pass the stopped host refused or cut ends its own worker,
# no new pass starts, and the passes in flight finish; the run exits 1 when any pass failed. The
# passes' host output goes to the log as it comes, so lines of passes at once interleave there.
set -u
job=comments
job_lock_kind=run
. "$(dirname "$0")/_job.sh"
. "$FLOW_PLUGIN/lib/branch.sh"
. "$FLOW_PLUGIN/lib/slots.sh"
host="${1:-}"; [ $# -eq 0 ] || shift
one=""; workers=""
while [ $# -gt 0 ]; do
  case "$1" in
    --workers) [ $# -ge 2 ] || die "--workers takes a number from 1" 2; workers="$2"; shift 2 ;;
    -*) die "unknown option $1" 2 ;;
    *) [ -n "$one" ] || one="$1"; shift ;;
  esac
done
job_start "$host" model
out="$(job_log_dir)/$job.out.$$"
slot_pool="$(job_log_dir)/$(job_base).slots"
trap 'c=$?; slot_give_all "$slot_pool" $$; rm -rf "$out.run"; rm -f "$out.login" "$out.procs" "$out.procs.failed" "$out.targets" "$out.gated"; job_end $c' EXIT
PASS_STOP_GRACE=10
PASS_LIMIT_EXIT=124
pass_limit="$(cfg_or jobs.comments.pass_limit 1h)"
pass_limit_seconds="$(cached_python3 -I "$FLOW_PLUGIN/scripts/_health.py" seconds jobs.comments.pass_limit "$pass_limit" 2>&1)" || die "${pass_limit_seconds#flow: }" 2
[ "$pass_limit_seconds" -ge 1 ] || die "jobs.comments.pass_limit is '$pass_limit': a pass needs at least 1s" 2
idle_session="$(cfg_or jobs.comments.idle_session 30m)"
idle_session_seconds="$(cached_python3 -I "$FLOW_PLUGIN/scripts/_health.py" seconds jobs.comments.idle_session "$idle_session" 2>&1)" || die "${idle_session_seconds#flow: }" 2
(unset -f gh; command -v gh >/dev/null 2>&1) || die "gh is not installed"
main="$(main_worktree)"; [ -n "$main" ] || main="$(pwd)"
targets=""; gated=""; rm -f "$out.gated"
if [ -n "$one" ]; then
  targets="$one"
else
  trackers="$(adapters_configured 2>&1)" || { printf '%s\n' "$trackers" >&2; job_say "error: ${trackers#flow: }" >/dev/null; exit 2; }
  for a in $trackers; do
    items_listed "$a" 2>/dev/null | cached_python3 -I -c '
import json, sys
for i in json.load(sys.stdin):
    pr = (i.get("state") or {}).get("pr", "")
    if i.get("status") == "open" and pr: print(i["id"], pr, (i.get("state") or {}).get("gate") or "none")'
  done | while read -r item pr gate; do
    # A gate other than merge is the owner's to answer first: a pass would stop at it again.
    case "$gate" in none|merge) ;; *) job_say "$item: waits at the $gate gate, skipped" >/dev/null; printf '%s (%s gate)\n' "$item" "$gate" >> "$out.gated"; continue ;; esac
    state="$("$FLOW_PLUGIN/scripts/comments.sh" state "$pr" 2>/dev/null)" || { job_say "$item: cannot read $pr" >/dev/null; continue; }
    if [ "$(json_get "$state" state)" = "OPEN" ]; then echo "$item"; else job_say "$item: $pr is $(json_get "$state" state), skipped" >/dev/null; fi
  done > "$out.targets"
  targets="$(cat "$out.targets")"; rm -f "$out.targets"
  gated="$(cat "$out.gated" 2>/dev/null | tr '\n' ',' | sed 's/,$//; s/,/, /g')"; rm -f "$out.gated"
fi
if [ -z "$targets" ]; then
  if [ -n "$gated" ]; then job_say "quiet: no open PR to address; at a gate: $gated"; else job_say "quiet: no open PR"; fi
  exit 0
fi
# prepare_pr <target>: chase its silent reviewers (not on a draft, which waits on its quiz in the console) and
# print the brief's notes: the PR conflicts with its base, checks fail on its head. Model free.
prepare_pr() {
  if adapter_for "$1" >/dev/null; then pull="$(state_get "$(item_read "$1" 2>/dev/null)" pr)"; else pull="$1"; fi
  [ -n "$pull" ] && state="$("$FLOW_PLUGIN/scripts/comments.sh" state "$pull" 2>/dev/null)" || return 0
  [ "$(json_get "$state" isDraft)" = "true" ] || chase_reviewers "$1" "$pull"
  conflict_note "$1" "$pull"
  checks_note "$1" "$pull"
}
conflict_note() { # conflict_note <target> <pr>, with $state read
  [ "$(json_get "$state" mergeable)" = "CONFLICTING" ] || return 0
  base="$(json_get "$state" baseRefName)"
  case "$base" in ""|*[!A-Za-z0-9._/-]*) job_say "$1: $2 conflicts with a base named oddly, not merged" >/dev/null; return 0 ;; esac
  job_say "$1: $2 conflicts with $base" >/dev/null
  printf ' The PR conflicts with its base %s: run the Conflicts step first.' "$base"
}
# checks_note <target> <pr>, with $state read. A draft too: its red check is its own change's, the
# quiz does not wait on it, and a fix while the owner takes the quiz leaves the PR green when it
# goes ready.
checks_note() {
  failing="$("$FLOW_PLUGIN/scripts/comments.sh" failing-checks "$2" 2>/dev/null | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
  [ -n "$failing" ] || return 0
  head="$(json_get "$state" headRefOid | cut -c1-8)"; head="${head:-the head}"
  job_say "$1: checks fail on $head of $2: $failing" >/dev/null
  printf ' Checks fail on %s: %s: run the Checks step, then the threads whatever it finds.' "$head" "$failing"
}
chase_reviewers() { # chase_reviewers <target> <pr>
  "$FLOW_PLUGIN/scripts/comments.sh" chase "$2" 2>&1 | while IFS= read -r line; do job_say "$1: $line" >/dev/null; done
}
# activity <target> <item>: one line that changes when anything lands on the PR, read after the chase.
# $awaiting holds the last comment ids of the unresolved threads whose last word is not the
# flow's reply, space separated, and they are part of the line. So is the time the item's last
# gate was cleared (gate.sh clear), once one was: a pass that stopped at a gate left the PR as it
# was, and the owner's answer is what is new; <item>'s, the item item_of found, for a PR named by
# number, so both names of one PR give one line. A line with no clear is the line before 1.23.0.
# The checks failing on the head close the line only when one fails, so a PR with none keeps the
# line it had before failing checks were read, and gets no extra pass after the upgrade.
activity() {
  awaiting=""; cleared=""
  if adapter_for "$1" >/dev/null; then
    data="$(item_read "$1" 2>/dev/null)"; pull="$(state_get "$data" pr)"; cleared="$(state_get "$data" answered_at)"
  else
    pull="$1"; [ -z "$2" ] || cleared="$(state_get "$(item_read "$2" 2>/dev/null)" answered_at)"
  fi
  [ -n "$pull" ] && act="$("$FLOW_PLUGIN/scripts/comments.sh" activity "$pull" 2>/dev/null)" || return 0
  awaiting="$(json_list "$act" awaiting | tr '\n' ' ' | sed 's/ $//')"
  failing="$(json_list "$act" failing | tr '\n' ',' | sed 's/,$//')"
  printf '%s %s %s threads:%s comments:%s awaiting:%s%s%s' "$(json_get "$act" updatedAt)" "$(json_get "$act" headRefOid)" "$(json_get "$act" mergeable)" \
    "$(json_get "$act" unresolved)" "$(json_get "$act" review_comments)" "$(printf '%s' "$awaiting" | tr ' ' ',')" "${cleared:+ cleared:$cleared}" \
    "${failing:+ failing:$failing}"
}
# cut_short <output file>: the host's own line when it stopped the pass's background work (Claude
# prints it when a subagent outlives its ceiling after the last turn), or nothing. Only a line that
# opens with it, near the end of the output, counts: the model's text may quote it.
CUT_SHORT='^Background tasks still running .*; stopping them\.'
cut_short() { tail -n 20 "$1" 2>/dev/null | grep -m1 -E "$CUT_SHORT"; }
# Per PR, beside the last good pass's activity (<pr>): <pr>.forced, the awaiting set a pass was
# forced for; <pr>.fails, the count of failed passes in a row, whatever they changed (a pass cut
# short after one reply changes the activity each time), cleared only by a pass that completes;
# <pr>.told and <pr>.told-fails, what the owner was last told. Each is said once. The in-use
# marker, pr-<number>.told-in-use, is keyed by the PR's number, so the item and the PR's number or
# URL, as a run by hand names it, share one; it goes when a pass addresses the PR.
# seen_file <key>: the record of the PR pr_key names, shared by every schedule of the job.
seen_file() { printf '%s/%s.seen/%s' "$(job_log_dir)" "$(job_base)" "$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"; }
# pr_number <text>: the PR number <text> names as a number, #<n> or a PR URL; nothing otherwise.
pr_number() {
  pr_number_text="${1##*/}"; pr_number_text="${pr_number_text#\#}"
  case "$pr_number_text" in ''|*[!0-9]*) ;; *) printf '%s' "$pr_number_text" ;; esac
}
# pr_key <target> <item>: one key per PR: the item the target names (item_of), else pr-<number>,
# else the target.
pr_key() {
  [ -z "$2" ] || { printf '%s' "$2"; return 0; }
  pr_key_number="$(pr_number "$1")"
  if [ -n "$pr_key_number" ]; then printf 'pr-%s' "$pr_key_number"; else printf '%s' "$1"; fi
}
max_fails="$(cfg_or jobs.comments.max_failures 3)"
case "$max_fails" in ''|*[!0-9]*) die "jobs.comments.max_failures takes a whole number" 2 ;; esac
COMMENTS_WORKERS_MAX=16
# worker_count <text>: <text> as a count of passes at once, its leading zeros stripped, when it is
# a whole number from 1 to COMMENTS_WORKERS_MAX, as the console takes it; returns 1 otherwise.
worker_count() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  count_digits="$1"
  while [ "${count_digits#0}" != "$count_digits" ]; do count_digits="${count_digits#0}"; done
  [ -n "$count_digits" ] && [ "${#count_digits}" -le "${#COMMENTS_WORKERS_MAX}" ] && [ "$count_digits" -le "$COMMENTS_WORKERS_MAX" ] || return 1
  printf '%s' "$count_digits"
}
[ -n "$workers" ] || workers="$(cfg_or jobs.comments_workers 1)"
workers="$(worker_count "$workers")" || die "--workers and jobs.comments_workers take a whole number from 1 to $COMMENTS_WORKERS_MAX" 2
tell() { "$FLOW_PLUGIN/scripts/notify.sh" --event comments "$1" >/dev/null 2>&1 || true; }
# item_of <target>: the item a target names: the target itself, or for a PR number the item of its
# head branch (branch_item); nothing for a PR the flow did not open.
item_of() {
  if adapter_for "$1" >/dev/null; then printf '%s' "$1"; return; fi
  io_head="$("$FLOW_PLUGIN/scripts/comments.sh" state "$1" 2>/dev/null | cached_python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("headRefName", ""))' 2>/dev/null)"
  branch_item "$io_head"
}
# pass_dir <target>: where the pass's session starts: the worktree the item holds, else the main
# worktree. A sandboxed Claude session commits only in the worktree it started in.
pass_dir() {
  pd_item="$(item_of "$1")"; pd_wt=""
  [ -z "$pd_item" ] || pd_wt="$("$FLOW_PLUGIN/scripts/steward.sh" find "$pd_item" 2>/dev/null)"
  if [ -n "$pd_wt" ] && [ -d "$pd_wt" ]; then printf '%s' "$pd_wt"; else printf '%s' "$main"; fi
}
# resume_note <target>: the item's comments-resume.md, the note a cut-short pass leaves for the
# next one (the shape of the health job's resume.md), in the reports folder the steward names.
resume_note() {
  rn_item="$(item_of "$1")"
  [ -n "$rn_item" ] || return 1
  rn_dir="$("$FLOW_PLUGIN/scripts/steward.sh" reports "$rn_item" 2>/dev/null)" || return 1
  printf '%s/comments-resume.md' "$rn_dir"
}
# answer_note <target> <record>: sets $answer_item, $answer_at and $answer to the brief's note on
# the owner's answer to the item's last gate, when it waits on this job (answer_pending comments:
# gate.sh clear at done); nothing else. $answer_at, the clear's time, names the answer: the pass
# writes it to <record> once it carried the answer out or raised it again as a gate.
answer_note() {
  answer=""; answer_at=""; answer_item="$(item_of "$1")"; [ -n "$answer_item" ] || return 0
  an_data="$(item_read "$answer_item" 2>/dev/null)"
  [ "$(state_get "$an_data" answer_pending)" = comments ] || return 0
  an_gate="$(state_get "$an_data" answered)"
  answer_at="$(state_get "$an_data" answered_at)"; answer_at="${answer_at:-unknown}"
  answer="$(printf ' The owner answered the %s gate: %s. Run the Answer step first; once it is carried out or raised again as a gate, write the line %s to %s.' \
    "${an_gate:-last}" "$(state_get "$an_data" answer | tr '\n' ' ' | sed 's/[. ]*$//')" "$answer_at" "$2")"
}
# answer_taken <record>: the pass confirmed the answer named $answer_at (answer_note).
answer_taken() { [ "$(head -n 1 "$1" 2>/dev/null)" = "$answer_at" ]; }
# take_answer <target>: the answer is taken, unless a newer one came while the pass ran (gate.sh
# clear takes no item lock): only the same answer, by its answered_at, is marked taken.
take_answer() {
  ta_data="$(item_read "$answer_item" 2>/dev/null)"
  [ "$(state_get "$ta_data" answer_pending)" = comments ] || return 0
  ta_at="$(state_get "$ta_data" answered_at)"
  if [ "${ta_at:-unknown}" != "$answer_at" ]; then
    job_say "$1: a newer answer to its gate came while the pass ran; it waits for the next pass" >/dev/null; return 0
  fi
  record_set "$answer_item" answer_pending= >/dev/null 2>&1 \
    || job_say "$1: could not mark the answer to its gate taken; the next pass carries it again" >/dev/null
}
# claimed_by <worktree> <item>: the worktree's claim names the item, so its changes are this
# item's. A released item's reports can sit in a pool worktree another item now holds.
claimed_by() { [ "$(json_get "$(cat "$1/.flow/claim.json" 2>/dev/null)" item)" = "$2" ]; }
# dirty_tree <worktree>: uncommitted changes outside .flow, untracked files counted even when the
# person's git config hides them (status.showUntrackedFiles=no).
dirty_tree() { [ -n "$(git -C "$1" status --porcelain --untracked-files=normal -- . ':!.flow' 2>/dev/null)" ]; }
# The flow's GitHub login, read at most once per run and only when a thread lacks the reply
# marker (a reply from before 1.19.0): comments.sh activity reads this cache.
FLOW_GH_LOGIN_CACHE="$out.login"; export FLOW_GH_LOGIN_CACHE
# list_procs: sets $procs to the process list's file, listing them the first time
# (FLOW_HEALTH_PROCS names a list, as for the health job); a failed listing leaves $procs.failed.
list_procs() {
  [ -z "$procs" ] || return 0
  procs="${FLOW_HEALTH_PROCS:-}"
  [ -n "$procs" ] || { procs="$out.procs"; cached_python3 -I "$FLOW_PLUGIN/scripts/_health.py" procs > "$procs" 2>/dev/null || : > "$procs.failed"; }
}
# in_use <target>: sets $in_use_why to why another session may be working in the worktree the
# item holds, or to nothing. Not run in a subshell: the processes are listed once per run, the
# first time a target holds a worktree, or before the workers start when passes run at once.
# When they cannot be listed, every worktree counts as in use, as the steward counts it.
in_use() {
  in_use_why=""; iu_how=""
  iu_item="$(item_of "$1")"; [ -n "$iu_item" ] || return 0
  iu_wt="$("$FLOW_PLUGIN/scripts/steward.sh" find "$iu_item" 2>/dev/null)"; [ -n "$iu_wt" ] || return 0
  list_procs
  if [ -f "$procs.failed" ]; then in_use_why="the processes cannot be listed, so a session may be working in $iu_wt"; return 0; fi
  iu_how="$(cached_python3 -I "$FLOW_PLUGIN/scripts/_health.py" alive "$procs" "$iu_item" "$iu_wt" "" 2>/dev/null)"
  [ -n "$iu_how" ] || return 0
  # A session a person left idle past jobs.comments.idle_session holds a worktree with nothing
  # uncommitted in it no longer: the pass has no work of theirs to edit under.
  if ! dirty_tree "$iu_wt"; then
    iu_idle="$iu_how"
    iu_how="$(cached_python3 -I "$FLOW_PLUGIN/scripts/_health.py" alive "$procs" "$iu_item" "$iu_wt" "" "$idle_session_seconds" 2>/dev/null)"
    [ -n "$iu_how" ] || { job_say "$1: $(session_named "$iu_idle") sits in $iu_wt past $idle_session with nothing uncommitted, so the pass runs" >/dev/null; return 0; }
  fi
  in_use_why="another session works in $iu_wt ($(session_named "$iu_how"))"
}
# once <file> <value>: true the first time <value> is seen for <file>, and records it.
once() { [ "$(cat "$1" 2>/dev/null)" != "$2" ] && printf '%s\n' "$2" > "$1"; }
# pr_of <target>: the PR a target names: the item's recorded PR, or the target itself.
pr_of() { if adapter_for "$1" >/dev/null; then state_get "$(item_read "$1" 2>/dev/null)" pr; else printf '%s' "$1"; fi; }
# in_use_marker <target> <pr>: the told-in-use marker of the PR <target> names, keyed by the PR's
# number (<pr> as a number, #<n> or URL); by the target when no PR is known.
in_use_marker() {
  marker_number="$(pr_number "$2")"
  if [ -n "$marker_number" ]; then seen_file "pr-$marker_number"; else seen_file "$1"; fi
  printf '.told-in-use'
}
# session_named <how>: the process _health.py alive named ("process 4242"), as a person reads it:
# "claude process 4242, idle 3d 2h" (busy, or running for a host that keeps no status); the words
# as they came when the process list lacks it.
session_named() {
  sn_pid="${1##* }"
  case "$sn_pid" in ''|*[!0-9]*) printf '%s' "$1"; return 0 ;; esac
  cached_python3 -I "$FLOW_PLUGIN/scripts/_health.py" session "$procs" "$sn_pid" 2>/dev/null || printf '%s' "$1"
}
# tell_in_use <target>: tells the owner once per streak that the PR waits on the session in_use
# found ($iu_item, $iu_wt, $iu_how). Nothing when the processes could not be listed: no session
# is known then.
tell_in_use() {
  [ -n "$iu_how" ] || return 0
  ti_pr="$(pr_of "$1")"; ti_f="$(in_use_marker "$1" "$ti_pr")"; mkdir -p "$(dirname "$ti_f")"
  ti_pr="${ti_pr##*/}"; ti_pr="${ti_pr#\#}"
  once "$ti_f" "$iu_wt" || return 0
  "$FLOW_PLUGIN/scripts/notify.sh" --event comments-skipped "$iu_item: the comments job skips PR #$ti_pr while $(session_named "$iu_how") works in $iu_wt. Its review comments wait until that session leaves the worktree; if nobody uses it, end it: kill ${iu_how##* }." >/dev/null 2>&1 || true
}
# outcome <word> [<why>]: what this pass came to, in its slot, for the run's result line:
# addressed, failed, unchanged, waits (on the owner), busy or stopped, and why.
outcome() { printf '%s\t%s\n' "$1" "${2:-}" > "$slot/outcome"; }
# pass_host_run <dir> <prompt> <group file>: job_host_run as the leader of its own session, its
# process group's id written to <group file>, stopped with its children at the pass limit.
pass_host_run() {
  cached_python3 -I "$FLOW_PLUGIN/scripts/_health.py" bounded "$pass_limit_seconds" "$PASS_STOP_GRACE" \
    sh -c 'printf "%s\n" "$$" > "$1"; shift; . "$FLOW_PLUGIN/lib/host.sh"; host_run "$@"' host_run "$3" "$host" "$1" "$2" "$(job_model)" "$(job_effort)" as-is
}
# pass_session <target> <notes>: the pass's host session on <target>, the brief's <notes> added,
# in a pass slot it waits for. The output goes to the log as it comes, so a pass killed half way
# keeps what it said, and to $out. Returns the host's exit code; starts nothing, with
# $in_use_why set, when the worktree came into use while it waited.
pass_session() {
  pass_slot="$(slot_try "$slot_pool" "$workers" $$)" || {
    # A run that names its PR says the wait where its caller reads it, with the runs that hold
    # the slots: the wait can last a whole pass, and a silent one reads as a hung job.
    if [ -n "$one" ]; then job_say "$1: waits for a free pass slot, $workers across the runs (held by run $(slot_holders "$slot_pool"))"
    else job_say "$1: waits for a free pass slot, $workers across the runs" >/dev/null; fi
    pass_slot="$(slot_take "$slot_pool" "$workers" $$)"
    # The person in_use passed over as idle may be back by now, or have left work in the tree.
    in_use "$1"
    [ -z "$in_use_why" ] || { slot_give "$pass_slot"; return 0; }
  }
  job_say "addressing $1"; rm -f "$(in_use_marker "$1" "$pull")"
  { pass_host_run "$(pass_dir "$1")" "$(host_skill_prompt "$host" flow comments "$1.$2 Unattended: nobody answers questions; collect owner decisions in the report, never wait on them, and address every thread before you end.")" "$pass_slot.group" 2>&1
    echo $? > "$out.code"; } | tee -a "$(job_log_dir)/$job.log" > "$out"
  slot_give "$pass_slot"
  session_code="$(cat "$out.code" 2>/dev/null)"
  return "${session_code:-1}"
}
# pass_failure <code> <answer record>: why the pass that ended with <code>, its output in $out,
# failed, or nothing when it completed.
pass_failure() {
  if [ "$1" -eq "$PASS_LIMIT_EXIT" ]; then printf 'stopped at the pass limit of %s (jobs.comments.pass_limit)' "$pass_limit"
  elif [ "$1" -ne 0 ]; then printf 'host exit %s' "$1"
  elif [ -n "$(cut_short "$out")" ]; then printf 'the host stopped the addresser before it finished'
  elif [ -n "$answer" ] && ! answer_taken "$2"; then printf "the pass did not confirm it carried out the owner's answer"; fi
}
# skip_in_use <target>: skips the pass on <target> for the session in_use found, and says why.
skip_in_use() {
  job_say "$1: $in_use_why, skipped" >/dev/null; tell_in_use "$1"
  if [ -n "$iu_how" ]; then outcome busy "$(session_named "$iu_how") in $(basename "$iu_wt")"; else outcome busy "processes not listed"; fi
}
# pass <target> <item>: one pass on one PR, its outcome in $slot.
pass() {
  t="$1"
  in_use "$t"
  if [ -n "$in_use_why" ]; then skip_in_use "$t"; return 0; fi
  note="$(prepare_pr "$t")"
  activity "$t" "$2" > "$out"; seen="$(cat "$out")"; f="$(seen_file "$(pr_key "$t" "$2")")"; mkdir -p "$(dirname "$f")"
  rm -f "$f.answer"; answer_note "$t" "$f.answer"
  fails=0
  [ -f "$f.fails" ] && { read -r fails _ < "$f.fails"; case "$fails" in ''|*[!0-9]*) fails=0 ;; esac; }
  if [ -z "$one" ] && [ "$fails" -ge "$max_fails" ]; then
    job_say "$t: $fails passes in a row failed, skipped until a pass run by hand completes" >/dev/null
    once "$f.told-fails" "$fails" && tell "$t: the comments pass failed $fails times in a row on $pull, so the job stops trying it. Read $(job_log_dir)/$job.log, then run it by hand: jobs/comments.sh <host> $t. A pass that completes lets the job try it again."
    outcome waits "$fails passes in a row failed"; return 0
  fi
  if [ -z "$one" ] && [ -z "$answer" ] && [ -n "$seen" ] && [ "$seen" = "$(cat "$f" 2>/dev/null)" ]; then
    if [ -z "$awaiting" ]; then
      job_say "$t: nothing new since the last pass, skipped" >/dev/null; outcome unchanged; return 0
    fi
    if [ "$(cat "$f.forced" 2>/dev/null)" = "$awaiting" ]; then
      job_say "$t: open thread(s) $awaiting still wait on a reply after a pass, skipped" >/dev/null
      once "$f.told" "$awaiting" && tell "$t: review thread(s) on $pull still wait on a reply after two passes (last comments $awaiting). Answer them, or run the pass by hand: jobs/comments.sh <host> $t."
      outcome waits "thread(s) $awaiting unanswered after two passes"; return 0
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
      printf 'An earlier run on PR #%s left uncommitted changes in %s (found by the comments job at %s). Read git status and git diff, continue from there, build and run only the tests the change touches before you commit, discard nothing without saying so in the reply.\n' \
        "${pull##*/}" "$rwt" "$(now_iso)" > "$resume"
      job_say "$t: $rwt holds uncommitted changes from an earlier run; the pass continues from them" >/dev/null
    fi
  fi
  [ -z "$resume" ] || [ ! -s "$resume" ] || rnote=" An earlier pass was cut short: read $resume first and continue from its work."
  pass_session "$t" "$note$answer$rnote"; code=$?
  # The saved activity goes, as for a stopped host, so the pass this run did not start still runs.
  if [ -n "$in_use_why" ]; then rm -f "$f"; skip_in_use "$t"; return 0; fi
  # A pass the stopped host refused or cut ends its worker: no later pass would start, and this PR
  # is tried again after the clear, with no failure counted. The saved activity goes, so the extra
  # pass this run may have marked as taken still runs. The stop's line is the run's last word.
  if [ "$code" -ne 0 ] && [ "$code" -ne "$PASS_LIMIT_EXIT" ] && job_host_stopped; then
    rm -f "$f"; printf '%s' "$job_last" > "$run/stopped"; outcome stopped; return 0
  fi
  why="$(pass_failure "$code" "$f.answer")"
  if [ -z "$why" ]; then
    [ -z "$seen" ] || printf '%s\n' "$seen" > "$f"
    rm -f "$f.fails" "$f.told-fails"
    # The note goes once the work it names is gone from the tree: an addresser that stopped
    # cleanly on a failing build leaves the changes, and the note stays for the next pass.
    if [ -n "$resume" ]; then
      rwt="${resume%/.flow/reports/*}"
      { claimed_by "$rwt" "$rn_item" && dirty_tree "$rwt"; } || rm -f "$resume"
    fi
    # The pass confirmed the owner's answer: carried out, or raised again as a gate when no step
    # of it could (the comments skill's Answer step). A failed pass leaves it waiting for the next.
    [ -z "$answer" ] || take_answer "$t"
    outcome addressed
  else
    rm -f "$f"
    printf '%s %s\n' "$((fails + 1))" "$seen" > "$f.fails"
    if [ "$((fails + 1))" -ge "$max_fails" ]; then job_say "$t: pass failed, $why; $((fails + 1)) in a row, so the job stops trying it until a pass run by hand completes"
    else job_say "$t: pass failed, $why; the next run tries it again"; fi
    if [ -n "$resume" ]; then
      rwt="${resume%/.flow/reports/*}"
      printf 'The previous comments pass on PR #%s was cut short at %s (%s). %s may hold its uncommitted work. Read git status and git diff, continue from there, build and run only the tests the change touches before you commit, discard nothing without saying so in the reply.\n' \
        "${pull##*/}" "$(now_iso)" "$why" "$rwt" > "$resume"
    fi
    outcome failed
  fi
}
# pass_lock <target> <item>: the lock a pass holds: its item's, else its PR's by number (a PR the
# flow did not open), else one keyed by the target.
pass_lock() {
  [ -z "$2" ] || { printf 'item:%s' "$(item_slug "$2")"; return 0; }
  pass_lock_number="$(pr_number "$1")"
  printf 'pr:%s' "${pass_lock_number:-$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')}"
}
# locked_pass <target>: the pass under its lock (pass_lock), taken with no wait.
locked_pass() {
  lp_item="$(item_of "$1")"
  if ! FLOW_LOCK_WAIT=0 flow_lock "$(pass_lock "$1" "$lp_item")"; then
    job_say "$1: another pass works on ${lp_item:-it} (its lock is held), skipped" >/dev/null; outcome busy "another pass holds its lock"; return 0
  fi
  pass "$1" "$lp_item"
  flow_unlock || true
}
# worker: runs passes one after another, each on the next target no other worker took (the first
# to make its slot, $run/<n>, takes it), until none is left or the host stopped. Always run in a
# subshell: the item lock's exit trap stays out of the run's, and each worker's $out is its own.
worker() {
  wk_n=0
  for wk_t in $targets; do
    wk_n=$((wk_n + 1))
    [ ! -f "$run/stopped" ] || return 0
    slot="$run/$wk_n"; mkdir_exclusive "$slot" || continue
    out="$slot/out"
    locked_pass "$wk_t"
  done
}
# The workers are subshells of this run in the background, joined by wait: they share its
# functions, targets and process list with no arguments to pass, and no run of their own shows in
# the job's status, as a re-run of this script per PR would.
run="$out.run"; mkdir -p "$run"; procs=""
if [ "$workers" -gt 1 ] && [ -z "$one" ]; then
  list_procs
  k=1
  while [ "$k" -le "$workers" ]; do (worker) & k=$((k + 1)); done
  wait
else
  (worker)
fi
# The result line: what each target came to, grouped, each PR named with why it got no pass.
addressed=0; done_list=""; failed=""; unchanged=0; same=""; waits=0; waits_list=""; busy=0; busy_list=""; n=0
tab="$(printf '\t')"
for t in $targets; do
  n=$((n + 1))
  oc="$(cat "$run/$n/outcome" 2>/dev/null)"; word="${oc%%"$tab"*}"; why=""
  case "$oc" in *"$tab"*) why="${oc#*"$tab"}" ;; esac
  case "$word" in
    addressed) addressed=$((addressed + 1)); done_list="$done_list, $t" ;;
    failed) addressed=$((addressed + 1)); failed="$failed $t" ;;
    unchanged) unchanged=$((unchanged + 1)); same="$same, $t" ;;
    waits) waits=$((waits + 1)); waits_list="$waits_list, $t ($why)" ;;
    busy) busy=$((busy + 1)); busy_list="$busy_list, $t${why:+ ($why)}" ;;
  esac
done
[ ! -f "$run/stopped" ] || [ -n "$failed" ] || { job_last="$(cat "$run/stopped")"; exit 0; }
rest=""
[ "$unchanged" -eq 0 ] || rest="$rest; nothing new on $unchanged PR(s): ${same#, }"
[ "$waits" -eq 0 ] || rest="$rest; $waits wait on you: ${waits_list#, }"
[ "$busy" -eq 0 ] || rest="$rest; $busy in use: ${busy_list#, }"
[ -z "$gated" ] || rest="$rest; at a gate: $gated"
if [ "$addressed" -eq 0 ]; then
  rest="${rest#; }"; job_say "quiet: ${rest:-nothing to address}"; exit 0
fi
if [ -n "$failed" ]; then
  job_say "failed:$failed cut short or failed, of $addressed PR(s) addressed$rest"; exit 1
fi
job_say "done: $addressed PR(s) addressed: ${done_list#, }$rest"
