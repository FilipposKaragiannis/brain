#!/bin/sh
# Retro job: the weekly retrospective over the lessons log, unattended.
#   jobs/retro.sh <claude|codex> [--min-lessons N] [--marketplace <path>]
# Counts the lessons since the last retro (the second column of <flow home>/retros.log is the
# number of lessons.jsonl lines read so far). Fewer than N new lessons (default 1): quiet exit,
# no model spend. Otherwise runs the meta `retro` skill in a fresh host session from the main
# worktree in unattended mode: marketplace findings become a PR on retro/<date>, project
# findings are listed in <flow home>/reports/retro-<date>.md, nothing is asked.
# Then lessons.jsonl and retros.log are committed and pushed, alone, when the main worktree is on
# the base branch (a file git ignores is left out; retro.commit: false turns it off), so a cloud
# session reads the same lessons. A quiet run commits the lessons recorded since, too.
set -u
job=retro
. "$(dirname "$0")/_job.sh"
host="${1:-}"; shift || true
min=1; market="$(cfg jobs.marketplace)"
while [ $# -gt 0 ]; do case "$1" in --min-lessons) min="$2"; shift 2 ;; --marketplace) market="$2"; shift 2 ;; *) die "unknown option $1" 2 ;; esac; done
job_start "$host"
home="$(flow_home)"; main="$(main_worktree)"; [ -n "$main" ] || main="$(pwd)"
total=0; [ -f "$home/lessons.jsonl" ] && total="$(grep -c . "$home/lessons.jsonl")"
read_so_far=0; [ -f "$home/retros.log" ] && read_so_far="$(tail -1 "$home/retros.log" | cut -f2)"
case "$read_so_far" in ''|*[!0-9]*) read_so_far=0 ;; esac
new=$((total - read_so_far)); [ "$new" -ge 0 ] || new="$total"
retro_commit() { [ "$(cfg retro.commit)" = "false" ] || job_commit lessons "lessons log" "$1" "$home/lessons.jsonl" "$home/retros.log"; }
[ "$new" -ge "$min" ] || { job_say "quiet: $new new lesson(s), minimum $min"; retro_commit "chore(flow): record the lessons [skip ci]"; exit 0; }
job_say "running over $new new lesson(s)"
host_run "$host" "$main" "$(host_skill_prompt "$host" meta retro "Unattended: nobody answers questions. Read the $new lessons since the last retro from $home/lessons.jsonl ($total lines, $read_so_far read before). Marketplace changes go in a PR${market:+ from the marketplace at $market}; project changes are listed, not applied, in $home/reports/retro-$(date +%F).md. Append the retros.log line with $total as the lessons read so far.")" "$(job_model)" "$(job_effort)" \
  >> "$(job_log_dir)/$job.log" 2>&1 || job_say "host exit $?"
[ -f "$home/reports/retro-$(date +%F).md" ] && job_say "report: $home/reports/retro-$(date +%F).md"
retro_commit "chore(flow): record the lessons the retro read [skip ci]"
job_say "done"
