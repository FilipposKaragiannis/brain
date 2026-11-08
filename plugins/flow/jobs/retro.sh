#!/bin/sh
# Retro job: the weekly retrospective over the lessons log, unattended.
#   jobs/retro.sh <claude|codex> [--min-lessons N] [--marketplace <path>] [--model <name>] [--effort <level>]
# Counts the lessons since the last retro: the lessons.jsonl lines whose time is after the time of
# the last <flow home>/retros.log line. A line count drifts when the log is rewritten (a checkout of
# an old branch that tracked it), so the second column of retros.log, the lines read so far, is
# written for the console and never used to find the new lessons. Fewer than N new lessons (default 1): quiet exit,
# no model spend. Otherwise runs the meta `retro` skill in a fresh host session from the main
# worktree in unattended mode: marketplace findings become a PR on retro/<date>, project
# findings are listed in <flow home>/reports/retro-<date>.md, nothing is asked.
# The lessons stay on this machine under the flow home: .flow/ is excluded from git, so the job
# commits nothing and each clone keeps its own lessons.
set -u
job=retro
. "$(dirname "$0")/_job.sh"
host="${1:-}"; shift || true
min=1; market="$(cfg jobs.marketplace)"
while [ $# -gt 0 ]; do case "$1" in --min-lessons) min="$2"; shift 2 ;; --marketplace) market="$2"; shift 2 ;; *) die "unknown option $1" 2 ;; esac; done
job_start "$host" model
home="$(flow_home)"; main="$(main_worktree)"; [ -n "$main" ] || main="$(pwd)"
total=0; [ -f "$home/lessons.jsonl" ] && total="$(grep -c . "$home/lessons.jsonl")"
since=''; [ -f "$home/retros.log" ] && since="$(tail -1 "$home/retros.log" | cut -f1)"
new=0; [ -f "$home/lessons.jsonl" ] && new="$(awk -v since="$since" 'match($0, /"time":"[^"]*"/) { if (substr($0, RSTART + 8, RLENGTH - 9) > since) n++ } END { print n + 0 }' "$home/lessons.jsonl")"
[ "$new" -ge "$min" ] || { job_say "quiet: $new new lesson(s), minimum $min"; exit 0; }
job_say "running over $new new lesson(s)"
job_host_run "$main" "$(host_skill_prompt "$host" meta retro "Unattended: nobody answers questions. Read the $new lessons since the last retro from $home/lessons.jsonl ($total lines; the new ones are those with a time after ${since:-the start}). Marketplace changes go in a PR${market:+ from the marketplace at $market}; project changes are listed, not applied, in $home/reports/retro-$(date +%F).md. Append the retros.log line with $total as the lessons read so far.")" \
  >> "$(job_log_dir)/$job.log" 2>&1 || { job_say "host exit $?"; job_host_stopped && exit 0; }
[ -f "$home/reports/retro-$(date +%F).md" ] && job_say "report: $home/reports/retro-$(date +%F).md"
job_say "done"
