#!/bin/sh
# next.sh [item] [--json] [--embed-agent]: prepare the next step of one item. Without an item,
# picks the first ready item, by rank (the tracker's priority), from every adapter that no run holds and that does not overlap a
# claim. Reads the state, selects the profile, claims a pool worktree when the step needs one,
# records the run, writes the step brief and prints what to run. The caller (the next skill in
# a session, or run-unattended.sh) runs the step and then calls advance.sh.
# Exit codes: 0 step ready · 3 no free worktree (pool at pool_max) · 4 waiting at a gate · 5 nothing
# ready · 6 item is done · 7 the item has a run in flight, or another run held the pick lock.
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
mkdir -p "$home/runs"
# Two runs started together must not pick the same item or claim the same worktree: the pick, the
# claim and the run record happen under one lock. The brief is written after it is released.
flow_lock pick || { echo "another run is picking an item for over ${FLOW_LOCK_WAIT:-60}s; try again" >&2; exit 7; }

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

if [ -z "$item" ]; then
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
  n="$(json_length "$ready" "")"
  i=0
  while [ "$i" -lt "$n" ]; do
    cand="$(json_get "$ready" "$i")"; cid="$(json_get "$cand" id)"
    i=$((i + 1))
    [ -f "$(run_file "$cid")" ] && continue
    mine="$(json_list "$cand" state.touches)"
    if [ -n "$mine" ] && touches_overlap "$mine" "$(claimed_touches "$cid")"; then continue; fi
    item="$cid"; break
  done
  [ -n "$item" ] || { echo "nothing ready: every ready item is running, overlaps a claim, or there is none" >&2; exit 5; }
fi

data="$(adapter read "$item")" || die "cannot read $item"
[ "$(json_get "$data" status)" = "open" ] || { echo "$item is closed" >&2; exit 6; }
kind="$(json_get "$data" kind)"; size="$(state_get "$data" size)"; [ -n "$size" ] || size="$(json_get "$data" size)"
[ -n "$size" ] || size="$(json_get "$profiles" default_size)"
profile="$(state_get "$data" profile)"
[ -n "$profile" ] || profile="$(profile_select "$kind" "$size")"
[ -n "$profile" ] || die "no profile for kind $kind size $size"
gate="$(state_get "$data" gate)"
if [ -n "$gate" ] && [ "$gate" != "none" ]; then
  echo "$item waits at gate '$gate'. Answer it, then: gate.sh clear $item" >&2; exit 4
fi
step="$(state_get "$data" step)"
[ -n "$step" ] || step="$(profile_steps "$profile" | head -1)"
[ "$step" = "done" ] && { echo "$item is done (every step ran). Merge or close it." >&2; exit 6; }
json_get "$profiles" "steps.$step" >/dev/null 2>&1 || die "unknown step '$step' for $item"
if [ -f "$(run_file "$item")" ]; then
  echo "$item already has a run in flight: $(cat "$(run_file "$item")"). Finish it with advance.sh, or delete the run file if that session died." >&2; exit 7
fi

attempts="$(state_get "$data" attempts)"; attempts="${attempts:-0}"; max_attempts="$(json_get "$profiles" max_attempts)"
agent="$(step_field "$step" agent)"; skill="$(step_field "$step" skill)"; summary="$(step_field "$step" summary)"
depth="$(json_get "$profiles" "review_depth.$profile")"
base="$(cfg_or base main)"
if [ "$(step_field "$step" worktree)" = "true" ]; then
  wt="$("$FLOW_PLUGIN/scripts/steward.sh" claim "$item" --base "$base")" || exit $?
  branch="$(json_get "$(cat "$wt/.flow/claim.json")" branch)"
  claim="$(cat "$wt/.flow/claim.json")"
  json_set "$claim" step "$(json_string "$step")" > "$wt/.flow/claim.json"
else
  wt="$(dirname "$home")"; branch="$(git -C "$wt" symbolic-ref --short -q HEAD || echo "$base")"
fi
reports="$(reports_dir "$item" "$wt")"; mkdir -p "$reports"
touches="$(json_list "$data" state.touches | python3 -I -c 'import json,sys; print(json.dumps([l.rstrip("\n") for l in sys.stdin if l.strip()]))')"
# The run's owner: the unattended loop (it exports its pid), else the host session that called this
# script. The health job reads it to tell a live run from a dead one.
owner="${FLOW_RUN_PID:-$(python3 -I "$FLOW_PLUGIN/scripts/_health.py" owner)}"
json_obj "item=$item" "step=$step" "profile=$profile" "worktree=$wt" "reports=$reports" "host=$(host_name)" \
  "started=$(now_iso)" ${owner:+"pid=$owner"} "touches:=$touches" > "$(run_file "$item")"
sized="size=$size"; [ "$kind" = "epic" ] && sized="size="
adapter write-state "$item" "step=$step" "profile=$profile" "$sized" "last_event=$(now_iso) start $step on $(host_name)" >/dev/null
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
  echo
  echo "## When you finish"
  echo "Write \`$reports/$step.json\`:"
  echo '```json'
  echo '{"status": "done | fail | gate", "summary": "one paragraph", "size": "S|M|L (only when your estimate changed)", "gate": "feel-test | ambiguity (status gate only)", "message": "what the owner must decide (status gate only); for ambiguity, numbered questions, one per line, each followed by a line Recommended: <your answer>, <why in a clause>", "touches": ["globs you changed or will change"]}'
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
  if [ -s "$reports/health.md" ]; then
    echo "## From the health job"
    echo
    cat "$reports/health.md"
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

out="$(json_obj "item=$item" "title=$(json_get "$data" title)" "kind=$kind" "size=$size" "profile=$profile" "depth=$depth" \
  "step=$step" "agent=$agent" "skill=$skill" "worktree=$wt" "branch=$branch" "base=$base" "brief=$brief" "reports=$reports" \
  "model=$(agent_model "$agent" 2>/dev/null)" "effort=$(agent_effort "$agent" 2>/dev/null)")"
if [ "$as_json" -eq 1 ]; then printf '%s\n' "$out"; else
  echo "next: $item - $step ($profile, $size)"
  echo "  run:   ${agent:-skill flow:$skill} in $wt"
  echo "  brief: $brief"
  echo "  then:  advance.sh $item"
fi
