#!/bin/sh
# next.sh [item] [--json] [--embed-agent] [--pick <name>]: prepare the next step of one item. Without an item,
# picks the first ready item, by rank (ready.priority_order), from every tracker read that no run holds.
# Items whose touches overlap may run side by side: the plan step puts an item behind another
# (state.held_by), and a held item is not ready (filter-ready.sh). --pick narrows the items read
# to the filter pick.<name> in .flow/config.yaml (pick_trackers in lib/flow.sh) before
# readiness, blockers, gates and the order apply; an unknown name exits 2.
# Reads the state, selects the profile, claims a pool worktree when the step needs one,
# records the run, writes the step brief and prints what to run. The caller (the next skill in
# a session, or run-unattended.sh) runs the step and then calls advance.sh.
# Exit codes: 0 step ready · 3 no free worktree (pool at pool_max) · 4 waiting at a gate, held behind an open item, or split
# and waiting on its children · 5 nothing ready · 6 item is done, or split with every child closed · 7 the item has a run in flight, or another run held the pick lock.
# Codes 4 and 6 are a named item's: a pick passes over an item with nothing to run (closed, at a
# gate, held, done, or split) and tries the next ready one, since the ready list it came from can
# be older than the item's state. A pick whose claim finds the pool full skips that item too, and
# from then on every item that holds no claim and whose step needs a worktree, with no tracker
# read and no claim attempt (scripts/_pick.py); it tries one that already holds a claim, or whose
# step needs no worktree. With nothing left it exits 3 when a claim found the pool full, else 5,
# and its last line says why: how many unclaimed items wait for a worktree, and what the claimed
# (or the ready) items are doing: running, held behind whom, at a gate, blocked. The retry
# re-runs this script with exec, so it keeps the pid; the skip list, the pool-full mark and the
# cached ready list count only when FLOW_NEXT_PID names this process.
. "$(dirname "$0")/../lib/flow.sh"
home="$(flow_home)"
profiles="$(cat "$FLOW_PLUGIN/profiles.json")"
item=""; as_json=0; embed=0; pick=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) as_json=1; shift ;;
    --embed-agent) embed=1; shift ;;
    --pick) [ $# -ge 2 ] || die "--pick takes a filter name from pick in .flow/config.yaml" 2; pick="$2"; shift 2 ;;
    -*) die "unknown option $1" 2 ;;
    *) item="$1"; shift ;;
  esac
done
named="$item"
[ -z "$pick" ] || [ -z "$item" ] || die "--pick narrows the ready list a pick reads; $item is named, so drop one of them" 2
ready_cache="$home/runs/.ready.$$"
if [ "${FLOW_NEXT_PID:-}" != "$$" ]; then FLOW_NEXT_SKIP=""; FLOW_NEXT_FULL=""; rm -f "$ready_cache"; fi
mkdir -p "$home/runs"
# pick_again: try the next ready item, without $item. Only a pick (no item named) can.
pick_again() {
  flow_unlock
  set --
  [ "$as_json" -eq 1 ] && set -- "$@" --json
  [ "$embed" -eq 1 ] && set -- "$@" --embed-agent
  [ -n "$pick" ] && set -- "$@" --pick "$pick"
  printf '%s\n%s\n' "$ready" "$notready" > "$ready_cache"
  FLOW_NEXT_PID=$$ FLOW_NEXT_SKIP="${FLOW_NEXT_SKIP:-} $item" FLOW_NEXT_FULL="${FLOW_NEXT_FULL:-}" exec "$0" "$@"
}
# pass_over <message> <code>: a picked item has nothing to run; say why and pick again. A named
# item exits with the code.
pass_over() { echo "$1" >&2; [ -z "$named" ] || exit "$2"; pick_again; }
run_file() { printf '%s/runs/%s.json' "$home" "$(item_slug "$1")"; }

# The ready list is read before the pick lock is taken: listing a tracker can take a minute, and
# a worker that waits that long on the lock gives up. The lock covers what must not race: the
# run records, the claim and the item's state, all read under it. Beside the ready list come the
# items the filter held back and why (FLOW_READY_NOTES in filter-ready.sh), for the reason a pick
# that finds nothing gives. The cache holds both, a line each.
notready=""
if [ -z "$item" ] && [ -f "$ready_cache" ]; then
  ready="$(sed -n 1p "$ready_cache")"; notready="$(sed -n 2p "$ready_cache")"; rm -f "$ready_cache"
elif [ -z "$item" ]; then
  ready_rules
  trackers="$(adapters_configured)" || exit 2
  # shellcheck disable=SC2086
  [ -z "$pick" ] || trackers="$(pick_trackers "$pick" $trackers)" || exit 2
  notes="$home/runs/.notes.$$"; rm -f "$notes"
  listed="$(FLOW_READY_NOTES="$notes"; export FLOW_READY_NOTES
    for a in $trackers; do adapter list-ready "$a" ${pick:+--pick "$pick"} 2>/dev/null; done | python3 -I -c '
import json, os, sys
seen, out = set(), []
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    for i in json.loads(line):
        if i["id"] not in seen:
            seen.add(i["id"]); out.append(i)
out.sort(key=lambda i: i.get("rank", 999))
print(json.dumps(out))
notes = [json.loads(l) for l in open(sys.argv[1], encoding="utf-8") if l.strip()] if os.path.exists(sys.argv[1]) else []
print(json.dumps(notes))' "$notes")"
  rm -f "$notes"
  ready="$(printf '%s\n' "$listed" | sed -n 1p)"; notready="$(printf '%s\n' "$listed" | sed -n 2p)"
fi
# Two runs started together must not pick the same item or claim the same worktree: the pick, the
# claim and the run record happen under one lock. The brief is written after it is released.
flow_lock pick || { echo "another run is picking an item for over ${FLOW_LOCK_WAIT:-60}s; try again" >&2; exit 7; }
if [ -z "$item" ]; then
  item="$(printf '%s\n%s\n' "$ready" "$notready" | python3 -I "$FLOW_PLUGIN/scripts/_pick.py" "$FLOW_PLUGIN" "$home/runs" "${FLOW_NEXT_FULL:-}" "${FLOW_NEXT_SKIP:-}")"; code=$?
  case "$code" in
    0) ;;
    3|5) echo "$item" >&2; exit "$code" ;;
    *) die "the pick failed (scripts/_pick.py exit $code)" ;;
  esac
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
# A plan put the item behind another (state.held_by): its steps after the plan wait while that one
# is open. The plan and the steps before it still run (a plan sent back is planned again, and that
# plan decides the hold anew), as in filter-ready.sh. A holder closed or not found holds nothing;
# next.sh lifts its hold below with the release note.
holder="$(state_get "$data" held_by)"
upto_plan="$(profile_steps "$profile" | sed '/^plan$/q')"
printf '%s\n' "$upto_plan" | grep -qx plan || upto_plan=""
if [ -n "$holder" ] && ! printf '%s\n' "$upto_plan" | grep -qx "$step" \
    && [ "$(json_get "$(adapter read "$holder" 2>/dev/null)" status)" = open ]; then
  why="$(state_get "$data" held_reason)"
  pass_over "$item is held behind $holder${why:+: $why}" 4
fi
if [ "$step" = "done" ]; then
  [ "$(state_get "$data" answer_pending)" != comments ] || pass_over "$item is done; its answer to the last gate waits on the comments job: jobs/comments.sh <host> $item" 6
  pass_over "$item is done (every step ran). Merge or close it." 6
fi
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
    if [ "$code" -eq 3 ] && [ -z "$named" ]; then FLOW_NEXT_FULL="$item"; pick_again; fi
    exit "$code"
  }
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
# A number in JSON has no leading zero, so the zeros go (never $((...)), which reads 0123 as octal).
case "$owner" in *[!0-9]*) owner="" ;; 0*) owner="${owner#"${owner%%[!0]*}"}"; owner="${owner:-0}" ;; esac
json_obj "item=$item" "step=$step" "profile=$profile" "worktree=$wt" "reports=$reports" "host=$(host_name)" \
  "started=$(now_iso)" ${owner:+"pid:=$owner"} "touches:=$touches" > "$(run_file "$item")"
sized="size=$size"; [ "$kind" = "epic" ] && sized="size="
# The run takes the answer to the last gate (answer_pending, gate.sh clear): its brief carries it.
taken=""; [ -z "$(state_get "$data" answer_pending)" ] || taken="answer_pending="
adapter write-state "$item" "step=$step" "profile=$profile" "$sized" ${taken:+"$taken"} "last_event=$(now_iso) start $step on $(host_name)" >/dev/null
flow_unlock

# Verify runs on the code the PR merges: a clean task branch behind its base gets the base merged
# in first. It runs after the pick lock: the run record makes the item and its worktree this run's,
# and a fetch under the lock would keep every other worker waiting. A merge that conflicts is
# aborted and handed to the sync step below (sync.md), so verify never runs on an unmerged branch.
if [ "$step" = verify ] && [ "$(step_field verify worktree)" = true ] && [ ! -s "$reports/sync.md" ] &&
   [ "$(git -C "$wt" symbolic-ref --short -q HEAD)" = "$branch" ] &&
   [ -z "$(git -C "$wt" status --porcelain -- . ":!.flow" 2>/dev/null)" ]; then
  vb="$(json_get "$claim" base)"; [ -n "$vb" ] || vb="$base"
  git -C "$wt" remote get-url origin >/dev/null 2>&1 && git -C "$wt" fetch -q origin "$vb" 2>/dev/null
  vref="$vb"; git -C "$wt" show-ref --verify --quiet "refs/remotes/origin/$vb" && vref="origin/$vb"
  behind="$(git -C "$wt" rev-list --count "HEAD..$vref" 2>/dev/null)"
  if [ "${behind:-0}" -gt 0 ]; then
    if git -C "$wt" merge -q --no-edit -m "chore: merge $vref into $branch" "$vref" >/dev/null 2>&1; then
      printf '%s\t%s\tsync\tmerged %s into %s (%s commits behind) before verify\n' "$(now_iso)" "$item" "$vref" "$branch" "$behind" >> "$home/events.log"
    else
      git -C "$wt" merge --abort >/dev/null 2>&1
      printf '%s\n' "$vref" > "$reports/sync.md"
    fi
  fi
fi
# A merge the health job could not make cleanly (sync.md, one ref per line) runs first as the sync
# step. The item keeps its own step, which runs once the sync is done.
own_step="$step"
if [ "$(step_field "$step" worktree)" = "true" ] && [ -s "$reports/sync.md" ]; then
  step=sync; agent="$(step_field sync agent)"; skill="$(step_field sync skill)"; summary="$(step_field sync summary)"
  json_set "$claim" step "$(json_string sync)" > "$wt/.flow/claim.json"
  json_set "$(cat "$(run_file "$item")")" step "$(json_string sync)" > "$(run_file "$item").tmp" && mv "$(run_file "$item").tmp" "$(run_file "$item")"
fi
# A hold (hold.sh, skills/plan/holds.md) ends when its holder closes: the item's own step, not a
# sync ahead of it, gets the release note, and the hold is lifted.
released=""; held_by="$(state_get "$data" held_by)"
if [ -n "$held_by" ] && [ "$step" != sync ] && hdata="$(adapter read "$held_by" 2>/dev/null)" && [ "$(json_get "$hdata" status)" = closed ]; then
  "$FLOW_PLUGIN/scripts/hold.sh" clear "$item" "$held_by closed" && released="$held_by"
fi
# The plan step judges the other open work its touches reach; with none the section is left out.
others=""; [ "$step" = plan ] && others="$("$FLOW_PLUGIN/scripts/hold.sh" candidates "$item" 2>/dev/null)"
# A plan run again while the item is still held (sent back at the gate) decides the hold anew.
still_held=""; [ "$step" = plan ] && [ -n "$held_by" ] && [ -z "$released" ] && still_held="$held_by"

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
  echo '{"status": "done | fail | gate", "summary": "markdown: one headline sentence, then at most six short bullets (scope, order, risks, what changed)", "size": "S|M|L (only when your estimate changed)", "gate": "feel-test | ambiguity (status gate only)", "pr": "the PR URL (pr step only)", "message": "markdown (status gate only): first line, in bold, the decision the owner must make; then short bullets of context; for ambiguity, numbered questions, one per line, each followed by a line Recommended: <your answer>, <why in a clause>", "touches": ["globs you changed or will change"]}'
  echo '```'
  [ "$step" != plan ] || echo "The plan step adds \`\"changes\": [\"the globs among touches whose existing behavior the plan changes; additive work is not a change\"]\`, and \`\"hold\"\` only as \`$FLOW_PLUGIN/skills/plan/holds.md\` says."
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
    echo "The flow could not bring \`$branch\` in step on its own (the health job, or the merge of the base before verify). Merge each ref below into it, in this order:"
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
  if [ -n "$released" ]; then
    rref="$base"; git -C "$wt" show-ref --verify --quiet "refs/remotes/origin/$base" && rref="origin/$base"
    echo "## The hold is over"
    echo
    echo "You were held behind $released, which has closed. First merge \`$rref\` into the branch (\`git fetch origin\` when there is one, then \`git merge $rref\`; never rebase), then check the plan still fits the code. If it does not, stop with status gate, gate ambiguity."
    echo
  fi
  if [ -n "$still_held" ]; then
    echo "## The hold now"
    echo
    echo "An earlier plan held this item behind $still_held: $(state_get "$data" held_reason). Your plan decides again: report \`hold\` behind it to keep the hold, or leave \`hold\` out and the hold is lifted."
    echo
  fi
  if [ -n "$others" ]; then
    echo "## Other open work"
    echo
    echo "Open items that hold a claim and change code your touches reach. Judge each by the rule in \`$FLOW_PLUGIN/skills/plan/holds.md\` and report \`hold\` only for a conflict:"
    echo
    printf '%s\n' "$others"
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
