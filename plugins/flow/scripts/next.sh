#!/bin/sh
# next.sh [item] [--json] [--embed-agent]: prepare the next step of one item. Without an item,
# picks the first ready item, by rank (the tracker's priority), from every adapter that no run holds and that does not overlap a
# claim. Reads the state, selects the profile, claims a pool worktree when the step needs one,
# records the run, writes the step brief and prints what to run. The caller (the next skill in
# a session, or run-unattended.sh) runs the step and then calls advance.sh.
# Exit codes: 0 step ready · 3 no free worktree (pool at pool_max) · 4 waiting at a gate, or split
# and waiting on its children · 5 nothing ready · 6 item is done, or split with every child closed · 7 the item has a run in flight, or another run held the pick lock.
# Codes 4 and 6 are a named item's: a pick passes over an item with nothing to run (closed, at a
# gate, done, or split) and tries the next ready one, since the ready list it came from can be
# older than the item's state. A pick whose claim finds the pool full skips that item too and
# tries one that already holds a claim, or whose step needs no worktree. With nothing left it
# exits 3 when a claim found the pool full, else 5. The retry re-runs this script with exec, so
# it keeps the pid; the skip list, the pool-full mark and the cached ready list count only when
# FLOW_NEXT_PID names this process.
. "$(dirname "$0")/../lib/flow.sh"
home="$(flow_home)"
profiles="$(cat "$FLOW_PLUGIN/profiles.json")"
item=""; as_json=0; embed=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) as_json=1; shift ;;
    --embed-agent) embed=1; shift ;;
    -*) die "unknown option $1" 2 ;;
    *) item="$1"; shift ;;
  esac
done
named="$item"
ready_cache="$home/runs/.ready.$$"
if [ "${FLOW_NEXT_PID:-}" != "$$" ]; then FLOW_NEXT_SKIP=""; FLOW_NEXT_FULL=""; rm -f "$ready_cache"; fi
mkdir -p "$home/runs"
# pick_again: try the next ready item, without $item. Only a pick (no item named) can.
pick_again() {
  flow_unlock
  set --
  [ "$as_json" -eq 1 ] && set -- "$@" --json
  [ "$embed" -eq 1 ] && set -- "$@" --embed-agent
  printf '%s\n' "$ready" > "$ready_cache"
  FLOW_NEXT_PID=$$ FLOW_NEXT_SKIP="${FLOW_NEXT_SKIP:-} $item" FLOW_NEXT_FULL="${FLOW_NEXT_FULL:-}" exec "$0" "$@"
}
# pass_over <message> <code>: a picked item has nothing to run; say why and pick again. A named
# item exits with the code.
pass_over() { echo "$1" >&2; [ -z "$named" ] || exit "$2"; pick_again; }
run_file() { printf '%s/runs/%s.json' "$home" "$(item_slug "$1")"; }

claimed_touches() {
  # touches globs of every claimed item, except $1, one per line
  for f in "$home"/runs/*.json; do
    [ -f "$f" ] || continue
    other="$(json_get "$(cat "$f")" item)"
    [ "$other" = "$1" ] && continue
    json_list "$(cat "$f")" touches
  done
}

# The ready list is read before the pick lock is taken: listing a tracker can take a minute, and
# a worker that waits that long on the lock gives up. The lock covers what must not race: the
# run records, the claim and the item's state, all read under it.
if [ -z "$item" ] && [ -f "$ready_cache" ]; then
  ready="$(cat "$ready_cache")"; rm -f "$ready_cache"
elif [ -z "$item" ]; then
  ready="$(for a in $(adapters_configured); do adapter list-ready "$a" 2>/dev/null; done | python3 -I -c '
import json, sys
seen, out = set(), []
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    for i in json.loads(line):
        if i["id"] not in seen:
            seen.add(i["id"]); out.append(i)
out.sort(key=lambda i: i.get("rank", 999))
print(json.dumps(out))')"
fi
# Two runs started together must not pick the same item or claim the same worktree: the pick, the
# claim and the run record happen under one lock. The brief is written after it is released.
flow_lock pick || { echo "another run is picking an item for over ${FLOW_LOCK_WAIT:-60}s; try again" >&2; exit 7; }
if [ -z "$item" ]; then
  n="$(json_length "$ready" "")"
  i=0
  while [ "$i" -lt "$n" ]; do
    cand="$(json_get "$ready" "$i")"; cid="$(json_get "$cand" id)"
    i=$((i + 1))
    [ -f "$(run_file "$cid")" ] && continue
    case " ${FLOW_NEXT_SKIP:-} " in *" $cid "*) continue ;; esac
    mine="$(json_list "$cand" state.touches)"
    if [ -n "$mine" ] && touches_overlap "$mine" "$(claimed_touches "$cid")"; then continue; fi
    item="$cid"; break
  done
  if [ -z "$item" ]; then
    [ -z "${FLOW_NEXT_FULL:-}" ] || { echo "no free worktree: every ready item left needs one, and the pool is at pool_max" >&2; exit 3; }
    echo "nothing ready: every ready item is running, overlaps a claim, has nothing left to run, or there is none" >&2; exit 5
  fi
fi

data="$(adapter read "$item")" || die "cannot read $item"
[ "$(json_get "$data" status)" = "open" ] || pass_over "$item is closed" 6
kind="$(json_get "$data" kind)"; size="$(state_get "$data" size)"; [ -n "$size" ] || size="$(json_get "$data" size)"
[ -n "$size" ] || size="$(json_get "$profiles" default_size)"
profile="$(state_get "$data" profile)"
[ -n "$profile" ] || profile="$(profile_select "$kind" "$size")"
[ -n "$profile" ] || die "no profile for kind $kind size $size"
gate="$(state_get "$data" gate)"
if [ -n "$gate" ] && [ "$gate" != "none" ]; then
  pass_over "$item waits at gate '$gate'. Answer it, then: gate.sh clear $item" 4
fi
step="$(state_get "$data" step)"
[ -n "$step" ] || step="$(profile_steps "$profile" | head -1)"
[ "$step" = "done" ] && pass_over "$item is done (every step ran). Merge or close it." 6
# A split item (steward.sh split) runs no step: its children do the work.
if [ "$step" = split ]; then
  kids="$(json_get "$data" open_children)"
  if [ "${kids:-0}" -gt 0 ] 2>/dev/null; then pass_over "$item is split and waits on its $kids open child item(s)" 4; fi
  pass_over "$item is split and every child is closed. Close it." 6
fi
json_get "$profiles" "steps.$step" >/dev/null 2>&1 || die "unknown step '$step' for $item"
if [ -f "$(run_file "$item")" ]; then
  echo "$item already has a run in flight: $(cat "$(run_file "$item")"). Finish it with advance.sh, or delete the run file if that session died." >&2; exit 7
fi

attempts="$(state_get "$data" attempts)"; attempts="${attempts:-0}"; max_attempts="$(json_get "$profiles" max_attempts)"
agent="$(step_field "$step" agent)"; skill="$(step_field "$step" skill)"; summary="$(step_field "$step" summary)"
depth="$(json_get "$profiles" "review_depth.$profile")"
# The architect runs where its cost pays: the profile's switch in profiles.json (architect).
architect=no; [ "$(json_get "$profiles" "architect.$profile")" = true ] && architect=yes
base="$(cfg_or base main)"
if [ "$(step_field "$step" worktree)" = "true" ]; then
  wt="$("$FLOW_PLUGIN/scripts/steward.sh" claim "$item" --base "$base")" || {
    code=$?
    if [ "$code" -eq 3 ] && [ -z "$named" ]; then FLOW_NEXT_FULL=1; pick_again; fi
    exit "$code"
  }
  branch="$(json_get "$(cat "$wt/.flow/claim.json")" branch)"
  claim="$(cat "$wt/.flow/claim.json")"
  json_set "$claim" step "$(json_string "$step")" > "$wt/.flow/claim.json"
else
  wt="$(dirname "$home")"; branch="$(git -C "$wt" symbolic-ref --short -q HEAD || echo "$base")"
fi
reports="$(reports_dir "$item" "$wt")"; mkdir -p "$reports"
# A merge the health job could not make cleanly (sync.md, one ref per line) runs first as the sync
# step. The item keeps its own step, which runs once the sync is done.
own_step="$step"
if [ "$(step_field "$step" worktree)" = "true" ] && [ -s "$reports/sync.md" ]; then
  step=sync; agent="$(step_field sync agent)"; skill="$(step_field sync skill)"; summary="$(step_field sync summary)"
  json_set "$claim" step "$(json_string sync)" > "$wt/.flow/claim.json"
fi
touches="$(json_list "$data" state.touches | python3 -I -c 'import json,sys; print(json.dumps([l.rstrip("\n") for l in sys.stdin if l.strip()]))')"
# The run's owner: the unattended loop (it exports its pid), else the host session that called this
# script. The health job reads it to tell a live run from a dead one.
owner="${FLOW_RUN_PID:-$(python3 -I "$FLOW_PLUGIN/scripts/_health.py" owner)}"
# A number in JSON has no leading zero, so the zeros go (never $((...)), which reads 0123 as octal).
case "$owner" in *[!0-9]*) owner="" ;; 0*) owner="${owner#"${owner%%[!0]*}"}"; owner="${owner:-0}" ;; esac
json_obj "item=$item" "step=$step" "profile=$profile" "worktree=$wt" "reports=$reports" "host=$(host_name)" \
  "started=$(now_iso)" ${owner:+"pid:=$owner"} "touches:=$touches" > "$(run_file "$item")"
sized="size=$size"; [ "$kind" = "epic" ] && sized="size="
adapter write-state "$item" "step=$own_step" "profile=$profile" "$sized" "last_event=$(now_iso) start $step on $(host_name)" >/dev/null
flow_unlock

brief="$reports/brief-$step.md"
{
  echo "# $item - step: $step"
  echo
  echo "**$summary**"
  echo
  echo "- Item: $item, kind $kind, size $size, profile $profile, review depth $depth, attempt $((attempts + 1)) of $max_attempts"
  echo "- Title: $(json_get "$data" title)"
  [ -n "$(json_get "$data" url)" ] && echo "- Tracker: $(json_get "$data" url)"
  echo "- Worktree: \`$wt\` on branch \`$branch\` (base \`$base\`). Start with \`cd \"$wt\"\`. Work only there."
  echo "- Reports: \`$reports\` (earlier step results and the plan live here)"
  echo "- Plugin: \`$FLOW_PLUGIN\` (scripts: \`scripts/verify.sh\`, \`scripts/steward.sh\`, \`scripts/comments.sh\`, adapters under \`adapters/\`)"
  if [ -n "$agent" ]; then echo "- Agent: $agent (its brief is your role)"; else echo "- Skill: invoke \`flow:$skill $item\`; it spawns what the step needs"; fi
  if [ "$step" = design ]; then
    if [ "$architect" = yes ]; then echo "- Architect: yes (profile $profile): the architect writes design.md after the exploration"
    else echo "- Architect: no (profile $profile): no architect; the step ends with the exploration, and the planner designs from it"; fi
  fi
  echo
  echo "## When you finish"
  echo "Write \`$reports/$step.json\`:"
  echo '```json'
  echo '{"status": "done | fail | gate", "summary": "markdown: one headline sentence, then at most six short bullets (scope, order, risks, what changed)", "size": "S|M|L (only when your estimate changed)", "gate": "feel-test | ambiguity (status gate only)", "message": "markdown (status gate only): first line, in bold, the decision the owner must make; then short bullets of context; for ambiguity, numbered questions, one per line, each followed by a line Recommended: <your answer>, <why in a clause>", "touches": ["globs you changed or will change"]}'
  echo '```'
  echo "Then stop. Do not advance the tracker yourself; the orchestrator calls advance.sh."
  echo "Stop with status fail when a check you cannot fix stays red; status gate when the codebase does not answer a question."
  echo
  answer="$(state_get "$data" answer)"; answered="$(state_get "$data" answered)"
  if [ -n "$answer" ]; then
    echo "## The owner's answer to the last gate${answered:+ ($answered)}"
    echo
    asked="$(state_get "$data" asked)"
    [ -n "$asked" ] && { echo "Asked:"; echo; printf '%s\n' "$asked"; echo; }
    echo "Answer: $answer"
    echo
  fi
  if [ "$step" = sync ]; then
    echo "## The merge"
    echo
    echo "The health job could not bring \`$branch\` in step on its own. Merge each ref below into it, in this order:"
    echo
    sed 's/^/- `/; s/$/`/' "$reports/sync.md"
    echo
    echo "1. \`git fetch origin\`, then \`git merge <ref>\` for each. Never rebase, never reset, never force."
    echo "2. Resolve each conflict so both sides keep their intent (your role's merge rules)."
    echo "3. Build and run the tests the conflicted files touch. Fix what the merge broke."
    echo "4. Commit each merge as \`chore: merge <ref> into $branch\`."
    echo "5. When \`origin/$branch\` exists, push with \`git push origin HEAD:$branch\`. A merge always fast-forwards it."
    echo
    echo "Two intents that cannot both hold: \`git merge --abort\` and stop with status gate, gate ambiguity, each file and the choice in the message."
    echo "Checks that stay red after the merge: stop with status fail, the merge committed but not pushed."
    echo "Your own step is $own_step; it runs after this one. Do none of it here."
    echo
  fi
  if [ -s "$reports/health.md" ] || [ -s "$reports/resume.md" ]; then
    echo "## From the health job"
    echo
    cat "$reports/health.md" "$reports/resume.md" 2>/dev/null
    echo
  fi
  echo "## The item"
  echo
  json_get "$data" body
  if [ "$embed" -eq 1 ] && [ -n "$agent" ] && [ -f "$FLOW_PLUGIN/agents/$agent.md" ]; then
    echo; echo "## Your role ($agent)"; echo
    awk 'BEGIN{n=0} /^---$/ {n++; next} n>=2 {print}' "$FLOW_PLUGIN/agents/$agent.md"
  fi
} > "$brief"
# The resume note is for the one brief after a resume; the branch flags in health.md stay until
# the health job clears them.
rm -f "$reports/resume.md"

out="$(json_obj "item=$item" "title=$(json_get "$data" title)" "kind=$kind" "size=$size" "profile=$profile" "depth=$depth" \
  "architect=$architect" "step=$step" "agent=$agent" "skill=$skill" "worktree=$wt" "branch=$branch" "base=$base" "brief=$brief" "reports=$reports" \
  "model=$(agent_model "$agent" 2>/dev/null)" "effort=$(agent_effort "$agent" 2>/dev/null)")"
if [ "$as_json" -eq 1 ]; then printf '%s\n' "$out"; else
  echo "next: $item - $step ($profile, $size)"
  echo "  run:   ${agent:-skill flow:$skill} in $wt"
  echo "  brief: $brief"
  echo "  then:  advance.sh $item"
fi
