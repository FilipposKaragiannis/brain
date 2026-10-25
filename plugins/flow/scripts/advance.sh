#!/bin/sh
# advance.sh <item> [--json] [--status done|fail|gate] [--summary TEXT] [--size S] [--gate NAME]
#            [--message TEXT]
# Applies a finished step: reads <reports>/<step>.json (flags override), updates attempts, size
# and touches, moves the state to the next step, raises the gate the profile puts there, and
# clears the run (a plan-approval gate listed in auto_gates for the item's size is not raised).
# A plan step that ends in tracker-tasks mode with children open splits the item (steward.sh split).
# Exit codes: 0 next step ready · 4 waiting at a gate, or split and waiting on its children · 6 done.
. "$(dirname "$0")/../lib/flow.sh"
home="$(flow_home)"
profiles="$(cat "$FLOW_PLUGIN/profiles.json")"
[ $# -ge 1 ] || die "usage: advance.sh <item> [--status ...]" 2
item="$1"; shift
as_json=0; status=""; summary=""; new_size=""; gate=""; message=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) as_json=1; shift ;;
    --status) status="$2"; shift 2 ;;
    --summary) summary="$2"; shift 2 ;;
    --size) new_size="$2"; shift 2 ;;
    --gate) gate="$2"; shift 2 ;;
    --message) message="$2"; shift 2 ;;
    *) die "unknown option $1" 2 ;;
  esac
done
run_file="$home/runs/$(item_slug "$item").json"
[ -f "$run_file" ] || die "$item has no run in flight (run next.sh $item first)" 2
run="$(cat "$run_file")"
step="$(json_get "$run" step)"; profile="$(json_get "$run" profile)"; wt="$(json_get "$run" worktree)"; reports="$(json_get "$run" reports)"
result=""; [ -f "$reports/$step.json" ] && result="$(cat "$reports/$step.json")"
[ -n "$status" ] || status="$(json_get "$result" status)"
[ -n "$summary" ] || summary="$(json_get "$result" summary)"
[ -n "$new_size" ] || new_size="$(json_get "$result" size)"
[ -n "$gate" ] || gate="$(json_get "$result" gate)"
[ -n "$message" ] || message="$(json_get "$result" message)"
touches="$(json_list "$result" touches | tr '\n' ',' | sed 's/,$//')"
# The verify step's result is the verify report itself: {status: pass|fail, checks, attempts}.
[ "$status" = "pass" ] && status=done
if [ "$step" = "verify" ] && [ -z "$summary" ] && [ -n "$result" ]; then
  summary="$(json_list "$result" checks | while read -r c; do printf '%s %s; ' "$(json_get "$c" name)" "$(json_get "$c" status)"; done)"
fi
[ -n "$status" ] || die "no result for step $step: write $reports/$step.json or pass --status" 2

data="$(adapter read "$item")" || die "cannot read $item"
attempts="$(state_get "$data" attempts)"; attempts="${attempts:-0}"
size="$(state_get "$data" size)"; [ -n "$size" ] || size="$(json_get "$data" size)"; [ -n "$size" ] || size="$(json_get "$profiles" default_size)"
kind="$(json_get "$data" kind)"

finish_run() { rm -f "$run_file"; }

size_index() { i=0; for s in $(json_list "$profiles" sizes); do [ "$s" = "$1" ] && { printf '%s' "$i"; return; }; i=$((i + 1)); done; printf '%s' -1; }

report() {
  # report <exit> <next-step> <gate>
  [ -n "$touches" ] && adapter write-state "$item" "touches=$touches" >/dev/null
  if [ "$as_json" -eq 1 ]; then json_obj "item=$item" "step=$step" "status=$status" "next_step=$2" "gate=$3" "profile=$profile" "size=$size" "attempts=$attempts"; echo
  else echo "advance: $item - $step $status -> ${2:-$3}"; fi
  exit "$1"
}

# The sync step runs ahead of the item's own step and never moves it: done drops the merge order,
# a gate or a failure stops at a gate, and the order stays for the run after it clears.
if [ "$step" = sync ]; then
  own="$(state_get "$data" step)"
  case "$status" in
    done)
      rm -f "$reports/sync.md"
      adapter write-state "$item" "last_event=$(now_iso) sync done -> $own" >/dev/null
      adapter comment "$item" --body "The task branch is in step: ${summary:-merged}. Next: $own." >/dev/null
      finish_run
      report 0 "$own" "" ;;
    gate)
      [ -n "$gate" ] || gate="ambiguity"
      "$FLOW_PLUGIN/scripts/gate.sh" raise "$item" "$gate" "${message:-$summary}" >/dev/null
      report 4 "" "$gate" ;;
    fail)
      "$FLOW_PLUGIN/scripts/gate.sh" raise "$item" escalation "The sync step could not merge into the task branch: ${summary:-no summary}" >/dev/null
      report 4 "" escalation ;;
    *) die "unknown status '$status' (done, fail or gate)" 2 ;;
  esac
fi

# A step the item was split during (the implement step found open children and ran steward.sh
# split) does not move it: it waits on its children. The split finishes now the run is gone.
if [ "$step" != sync ] && [ "$(state_get "$data" step)" = split ]; then
  finish_run
  "$FLOW_PLUGIN/scripts/steward.sh" split "$item" >/dev/null 2>&1 || true
  report 4 split ""
fi
# A plan step that made tracker tasks of the item (plan.md says so) and left children open ends
# with the split: step split, the worktree back to the pool (steward.sh split). A gate it asks
# for is raised first; on the decomposition gate the owner can still keep it whole.
if [ "$step" = plan ] && [ "$status" != fail ] && [ "$(json_get "$data" open_children)" -gt 0 ] 2>/dev/null &&
   grep -qiE '^Decomposition:[[:space:]]*tracker tasks' "$reports/plan.md" 2>/dev/null; then
  if [ "$status" = gate ]; then
    [ -n "$gate" ] || gate="decomposition"
    hint=""; [ "$gate" != decomposition ] || hint=" To keep it whole instead, close its children, then clear the gate: the plan step runs again."
    "$FLOW_PLUGIN/scripts/gate.sh" raise "$item" "$gate" "${message:-$summary}$hint" >/dev/null
  else
    gate=""; finish_run
  fi
  "$FLOW_PLUGIN/scripts/steward.sh" split "$item" >/dev/null 2>&1 || true
  report 4 split "$gate"
fi

case "$status" in
  gate)
    [ -n "$gate" ] || gate="ambiguity"
    "$FLOW_PLUGIN/scripts/gate.sh" raise "$item" "$gate" "${message:-$summary}" >/dev/null
    adapter write-state "$item" "step=$step" >/dev/null
    report 4 "" "$gate" ;;
  fail)
    attempts=$((attempts + 1))
    max="$(json_get "$profiles" max_attempts)"
    if [ "$attempts" -ge "${max:-3}" ]; then
      adapter write-state "$item" "attempts=$attempts" >/dev/null
      "$FLOW_PLUGIN/scripts/gate.sh" raise "$item" escalation "Step $step failed $attempts times. Last: ${summary:-no summary}" >/dev/null
      report 4 "" escalation
    fi
    fix="$(json_get "$profiles" "fix_step.$step")"; [ -n "$fix" ] || fix="$step"
    adapter write-state "$item" "step=$fix" "attempts=$attempts" "last_event=$(now_iso) $step failed (attempt $attempts): ${summary:-no summary}" >/dev/null
    adapter comment "$item" --body "Step $step failed (attempt $attempts of ${max:-3}): ${summary:-no summary}. Back to $fix." >/dev/null
    finish_run
    report 0 "$fix" "" ;;
  done) ;;
  *) die "unknown status '$status' (done, fail or gate)" 2 ;;
esac

# done: a passing verify that touched rendered code raises the feel-test gate after moving on.
feel_test=0
[ "$step" = "$(json_get "$profiles" feel_test_step)" ] && [ "$(json_get "$result" feel_test)" = "true" ] && feel_test=1
# re-size at the step boundary, then move on.
next_profile="$profile"
if [ -n "$new_size" ] && [ "$new_size" != "$size" ]; then
  old_i="$(size_index "$size")"; new_i="$(size_index "$new_size")"
  [ "$new_i" -ge 0 ] || die "unknown size $new_size" 2
  adapter write-state "$item" "size=$new_size" >/dev/null
  if [ $((new_i - old_i)) -ge 2 ] || { [ "$new_size" = "L" ] && [ "$new_i" -gt "$old_i" ]; }; then
    adapter write-state "$item" "step=$step" "profile=$(profile_select "$kind" "$new_size")" >/dev/null
    "$FLOW_PLUGIN/scripts/gate.sh" raise "$item" plan-approval "Re-sized $size -> $new_size at step $step: ${summary:-no summary}. Replan or split, then clear the gate." >/dev/null
    size="$new_size"; report 4 "" plan-approval
  fi
  size="$new_size"
  next_profile="$(profile_select "$kind" "$new_size")"
  [ "$next_profile" = "$profile" ] || adapter comment "$item" --body "Re-sized $size: profile $profile -> $next_profile, continuing with the added depth." >/dev/null
fi
following="$(profile_steps "$next_profile" | awk -v s="$step" 'f {print; exit} $0 == s {f = 1}')"
if [ -z "$following" ] && [ "$next_profile" != "$profile" ]; then
  following="$(profile_steps "$next_profile" | head -1)"
fi
profile="$next_profile"
attempts=0
if [ -z "$following" ]; then
  adapter write-state "$item" "step=done" "profile=$profile" "attempts=0" "last_event=$(now_iso) $step done; every step ran" >/dev/null
  adapter comment "$item" --body "Step $step done: ${summary:-no summary}. Every step of $profile ran." >/dev/null
  finish_run
  report 6 "done" ""
fi
case "$following" in
  gate:*)
    g="${following#gate:}"
    after="$(profile_steps "$profile" | awk -v s="$following" 'f {print; exit} $0 == s {f = 1}')"
    [ -n "$after" ] || after="done"
    # auto_gates: only plan-approval can be cleared by the flow, by item size; every other gate waits.
    if [ "$g" = "plan-approval" ] && case ",$(cfg auto_gates.plan-approval | tr -d ' ')," in *",$size,"*) true ;; *) false ;; esac; then
      adapter write-state "$item" "step=$after" "profile=$profile" "attempts=0" "last_event=$(now_iso) $step done; gate $g auto-approved (size $size)" >/dev/null
      adapter comment "$item" --body "Step $step done: ${summary:-no summary}. Gate $g auto-approved by auto_gates for size $size. Next: $after." >/dev/null
      printf '%s\t%s\t%s\t%s\n' "$(now_iso)" "$item" "$g" "auto-approved (size $size)" >> "$home/events.log"
      finish_run
      report 0 "$after" ""
    fi
    adapter write-state "$item" "step=$after" "profile=$profile" "attempts=0" "last_event=$(now_iso) $step done; gate $g" >/dev/null
    "$FLOW_PLUGIN/scripts/gate.sh" raise "$item" "$g" "${summary:-$step done}. $(json_get "$profiles" "gates.$g.says")" >/dev/null
    report 4 "$after" "$g" ;;
  *)
    adapter write-state "$item" "step=$following" "profile=$profile" "attempts=0" "last_event=$(now_iso) $step done -> $following" >/dev/null
    adapter comment "$item" --body "Step $step done: ${summary:-no summary}. Next: $following." >/dev/null
    if [ "$feel_test" -eq 1 ]; then
      "$FLOW_PLUGIN/scripts/gate.sh" raise "$item" feel-test "Verify passed and the change touches rendered code. $(json_get "$profiles" "gates.feel-test.says"): see $reports/verify.md. Clear the gate to continue with $following." >/dev/null
      report 4 "$following" feel-test
    fi
    finish_run
    report 0 "$following" "" ;;
esac
