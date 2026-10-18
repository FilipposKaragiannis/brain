#!/bin/sh
# Intake job: turn the owner's notes into tracker items.
#   jobs/intake.sh <claude|codex> [--notes PATH] [--batch N] [--keep-notes]
# Reads the next unfiled notes from intake.notes in .flow/config.yaml (or --notes), at most
# intake.batch of them (default 10), and runs the flow `intake` skill on each note in its own
# host session from the main worktree, one after another, so every note gets a fresh context and
# sees the items the note before it filed. The skill files the note as an item, names the open
# item it duplicates, answers a question, or drops a note with its reason, and writes a results
# file. After each session this script records the note in the ledger
# (<flow home>/log/intake-ledger.jsonl), appends an answer to intake.answers and a dropped note's
# reason to intake.dropped (default answers.md and dropped.md beside the notes), and removes the
# note from the notes file; --keep-notes leaves the file as it is and relies on the ledger alone. A
# relative path is read from the main worktree. A notes file git tracks is committed and pushed
# after the run with those two pages, alone, when the main worktree is on the base branch
# (intake.commit: false turns it off), so a cloud session reads the same notes. No new notes: a
# quiet exit, no model spend.
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
main="$(main_worktree)"; [ -n "$main" ] || main="$(pwd)"
resolve() { case "$1" in "~/"*) printf '%s' "$HOME/${1#\~/}" ;; /*) printf '%s' "$1" ;; *) printf '%s/%s' "$main" "$1" ;; esac; }
notes="$(resolve "$notes")"
answers="$(cfg intake.answers)"; if [ -n "$answers" ]; then answers="$(resolve "$answers")"; else answers="$(dirname "$notes")/answers.md"; fi
dropped="$(cfg intake.dropped)"; if [ -n "$dropped" ]; then dropped="$(resolve "$dropped")"; else dropped="$(dirname "$notes")/dropped.md"; fi
[ -f "$notes" ] || { job_say "quiet: no notes file at $notes"; exit 0; }
ledger="$(job_log_dir)/intake-ledger.jsonl"
run="$(flow_home)/tmp/intake-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$run"
python3 -I "$FLOW_PLUGIN/scripts/_intake.py" parse "$notes" "$ledger" "$batch" > "$run/notes.json" || die "cannot read $notes"
count="$(json_length "$(cat "$run/notes.json")" notes)"; left="$(json_get "$(cat "$run/notes.json")" left)"
[ "$count" -gt 0 ] || { job_say "quiet: no new notes"; rm -rf "$run"; exit 0; }
job_say "filing $count note(s) from $notes, $left more after this batch"
missing=0
# The tracker's issue types and area options reach every session, so the skill names real ones.
words="$(adapter_for_kind task)"
[ -x "$FLOW_PLUGIN/adapters/$words/vocabulary.sh" ] && { adapter vocabulary "$words" > "$run/vocabulary.json" 2>>"$(job_log_dir)/$job.log" || job_say "could not read the types and areas"; }
for id in $(python3 -I "$FLOW_PLUGIN/scripts/_intake.py" split "$run/notes.json" "$run" "$run/vocabulary.json"); do
  host_run "$host" "$main" "$(host_skill_prompt "$host" flow intake "on $run/$id/notes.json and write $run/$id/results.json. Unattended: nobody answers questions; a note that needs the owner is filed and gated, never parked.")" "$(job_model)" "$(job_effort)" \
    >> "$(job_log_dir)/$job.log" 2>&1 || job_say "$id: host exit $?"
  if [ -f "$run/$id/results.json" ]; then
    python3 -I "$FLOW_PLUGIN/scripts/_intake.py" apply "$notes" "$ledger" "$run/$id/notes.json" "$run/$id/results.json" "$keep" "$answers" "$dropped" \
      >/dev/null 2>>"$(job_log_dir)/$job.log" || { job_say "$id: could not apply $run/$id/results.json"; missing=$((missing + 1)); }
  else
    job_say "$id: no results file, left in the notes"; missing=$((missing + 1))
  fi
done
summary="$(python3 -I "$FLOW_PLUGIN/scripts/_intake.py" tally "$run")"
job_say "done: $summary"
"$FLOW_PLUGIN/scripts/notify.sh" --event intake "notes filed: $summary" >/dev/null 2>&1 || true
if [ "$keep" -eq 0 ] && [ "$(cfg intake.commit)" != "false" ] && git -C "$main" ls-files --error-unmatch "$notes" >/dev/null 2>&1; then
  base="$(cfg_or base main)"
  if [ "$(git -C "$main" symbolic-ref --short HEAD 2>/dev/null)" != "$base" ]; then
    job_say "the main worktree is not on $base: the notes file is left uncommitted"
  else
    pages=""
    for f in "$answers" "$dropped"; do
      case "$f" in "$main"/*) [ -f "$f" ] && pages="$pages $f" ;; esac
    done
    # shellcheck disable=SC2086
    [ -z "$pages" ] || git -C "$main" add -- $pages >/dev/null 2>&1
    # shellcheck disable=SC2086
    if ! git -C "$main" diff --quiet HEAD -- "$notes" $pages; then
      git -C "$main" commit -q --only -m "chore(notes): file notes as tracker items [skip ci]" -- "$notes" $pages >/dev/null 2>&1 \
        || job_say "could not commit the notes file"
    fi
    # shellcheck disable=SC2086
    ours="$(git -C "$main" ls-files --full-name -- "$notes" $pages | sort)"
    ahead="$(git -C "$main" diff --name-only "$(git -C "$main" merge-base "origin/$base" "$base" 2>/dev/null)" "$base" 2>/dev/null | sort)"
    if [ -n "$ahead" ] && [ -n "$(printf '%s\n' "$ahead" | grep -vxF "$ours")" ]; then
      job_say "$base has other unpushed changes: the notes commit waits for your push"
    elif [ -n "$ahead" ]; then
      git -C "$main" push -q origin "$base" >/dev/null 2>&1 && job_say "notes file pushed" || job_say "notes file committed; the push failed, the next run retries"
    fi
  fi
fi
[ "$missing" -eq 0 ] || exit 1
