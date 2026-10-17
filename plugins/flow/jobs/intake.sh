#!/bin/sh
# Intake job: turn the owner's notes into tracker items.
#   jobs/intake.sh <claude|codex> [--notes PATH] [--batch N] [--keep-notes]
# Reads the next unfiled notes from intake.notes in .flow/config.yaml (or --notes), at most
# intake.batch of them (default 10), and runs the flow `intake` skill once on them from the main
# worktree. The skill files each note as an item, or names the open item it duplicates, and
# writes a results file. This script then records each handled note in the ledger
# (<flow home>/log/intake-ledger.jsonl) and removes it from the notes file; --keep-notes leaves
# the file as it is and relies on the ledger alone. No new notes: a quiet exit, no model spend.
# Schedule it nightly; the lock skips an overlap.
set -u
job=intake
. "$(dirname "$0")/_job.sh"
host="${1:-}"; shift || true
notes="$(cfg intake.notes)"; batch="$(cfg_or intake.batch 10)"; keep=0
while [ $# -gt 0 ]; do
  case "$1" in
    --notes) notes="$2"; shift 2 ;;
    --batch) batch="$2"; shift 2 ;;
    --keep-notes) keep=1; shift ;;
    *) die "unknown option $1" 2 ;;
  esac
done
case "$batch" in ''|*[!0-9]*|0) die "--batch takes a number from 1" 2 ;; esac
job_start "$host"
[ -n "$notes" ] || die "no notes file: set intake.notes in .flow/config.yaml or pass --notes"
case "$notes" in "~/"*) notes="$HOME/${notes#\~/}" ;; esac
[ -f "$notes" ] || { job_say "quiet: no notes file at $notes"; exit 0; }
ledger="$(job_log_dir)/intake-ledger.jsonl"
run="$(flow_home)/tmp/intake-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$run"
python3 -I "$FLOW_PLUGIN/scripts/_intake.py" parse "$notes" "$ledger" "$batch" > "$run/notes.json" || die "cannot read $notes"
count="$(json_length "$(cat "$run/notes.json")" notes)"; left="$(json_get "$(cat "$run/notes.json")" left)"
[ "$count" -gt 0 ] || { job_say "quiet: no new notes"; rm -rf "$run"; exit 0; }
job_say "filing $count note(s) from $notes, $left more after this batch"
main="$(main_worktree)"; [ -n "$main" ] || main="$(pwd)"
host_run "$host" "$main" "Invoke the flow plugin's intake skill (Claude: /flow:intake, Codex: \$intake) on $run/notes.json and write $run/results.json. Unattended: nobody answers questions; a note that needs the owner is filed and gated." "$(job_model)" "$(job_effort)" \
  >> "$(job_log_dir)/$job.log" 2>&1 || job_say "host exit $?"
[ -f "$run/results.json" ] || { job_say "no results file: nothing removed from the notes"; exit 1; }
summary="$(python3 -I "$FLOW_PLUGIN/scripts/_intake.py" apply "$notes" "$ledger" "$run/notes.json" "$run/results.json" "$keep" 2>>"$(job_log_dir)/$job.log")" \
  || { job_say "could not apply the results in $run"; exit 1; }
job_say "done: $summary"
"$FLOW_PLUGIN/scripts/notify.sh" --event intake "notes filed: $summary" >/dev/null 2>&1 || true
