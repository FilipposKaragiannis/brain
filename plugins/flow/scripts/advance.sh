#!/bin/sh
# advance.sh <item> [--json] [--status done|fail|gate] [--summary TEXT] [--size S] [--gate NAME]
#            [--message TEXT]
# Applies a finished step: reads <reports>/<step>.json (flags override), updates attempts, size
# and touches, moves the state to the next step, raises the gate the profile puts there, and
# clears the run (a plan-approval gate listed in auto_gates for the item's size is not raised).
# A step that stops at a gate raises it with the options and condition its result names.
# A plan step also records its changes and, done with a hold, holds the item behind another
# (hold.sh set; skills/plan/holds.md); done without one, it lifts a hold an earlier plan set.
# A plan step that ends in tracker-tasks mode with children open splits the item (steward.sh split).
# A pr step done with no PR recorded looks for one on the task branch, as the sweep does: one found
# is recorded and the merge gate raised; with none and nothing to merge (a clean tree and no diff
# against the claim's base) the item closes and its worktree is released, no merge gate raised;
# with none and changes to merge it raises an escalation gate. A lookup gh cannot answer leaves
# changes at the merge gate, where the sweep looks again.
# A gate and the step past it are one tracker write (gate.sh raise ... -- step=...), and a re-size
# lands in the write that moves the step: a write the tracker refuses leaves the item at its step,
# size and profile with its run, and advance.sh run again applies the step again. The run keeps
# the gate the step asked for, so the retry does not ask it again.
# That retry can still double what it repeats before the write: the "Step ... done" and re-size
# comments, the plan's hold line in events.log; and after a stop between a write and the run's
# removal, the gate comment and notification, and a failed step's attempt. The state, the gate
# and its record stay one.
# Exit codes: 0 next step ready · 1 a state write failed (the touches, the plan's changes or hold,
# the gate, an attempt, or the next step with its size) · 4 waiting at a gate, or split and
# waiting on its children · 6 done.
. "$(dirname "$0")/../lib/flow.sh"
. "$FLOW_PLUGIN/lib/base.sh"
. "$FLOW_PLUGIN/lib/pull_request.sh"
home="$(flow_home)"
profiles="$(cat "$FLOW_PLUGIN/profiles.json")"
HOLD_NOT_WRITTEN=3
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
options="$(json_get "$result" options)"; condition="$(json_get "$result" condition)"
touches="$(json_list "$result" touches | tr '\n' ',' | sed 's/,$//')"
# The verify step's result is the verify report itself: {status: pass|fail, checks, attempts}.
[ "$status" = "pass" ] && status=done
if [ "$step" = "verify" ] && [ -z "$summary" ] && [ -n "$result" ]; then
  summary="$(json_list "$result" checks | while read -r c; do printf '%s %s; ' "$(json_get "$c" name)" "$(json_get "$c" status)"; done)"
fi
[ -n "$status" ] || die "no result for step $step: write $reports/$step.json or pass --status" 2
[ "$status" != gate ] || gate_known "${gate:-ambiguity}" || die "the result of step $step names a gate profiles.json does not have; nothing written, fix $reports/$step.json or pass --gate" 2

data="$(adapter read "$item")" || die "cannot read $item"
attempts="$(state_get "$data" attempts)"; case "$attempts" in ''|*[!0-9]*) attempts=0 ;; 0*) attempts="${attempts#"${attempts%%[!0]*}"}"; attempts="${attempts:-0}" ;; esac
size="$(state_get "$data" size)"; [ -n "$size" ] || size="$(json_get "$data" size)"; [ -n "$size" ] || size="$(json_get "$profiles" default_size)"
kind="$(json_get "$data" kind)"
# The pr step's worker may be unable to record its PR (a local item file lies outside its
# sandbox): the URL its result names is recorded here when the item has none.
if [ "$step" = pr ] && pr_url="$(json_get "$result" pr)" && [ -n "$pr_url" ] && [ -z "$(state_get "$data" pr)" ]; then
  adapter link-pr "$item" "$pr_url" >/dev/null || echo "advance: could not record $pr_url on $item" >&2
fi

finish_run() { rm -f "$run_file"; }
# The gate a step asked for by itself, `<step> <gate>` in <flow home>/asked/<item>, kept until the
# step ends: the profile's gate after that step would ask the owner the same question again.
asked_file="$home/asked/$(item_slug "$item")"

# raise_asked <gate> <message>: raise the gate the step asked for, with the options and condition
# its result names; an empty options list is no options.
raise_asked() {
  set -- "$item" "$1" "$2"
  case "$options" in ""|"[]") ;; *) set -- "$@" --options "$options" ;; esac
  [ -z "$condition" ] || set -- "$@" --condition "$condition"
  "$FLOW_PLUGIN/scripts/gate.sh" raise "$@" >/dev/null || gate_not_recorded "$2"
}

gate_not_recorded() {
  die "the $1 gate on $item did not finish raising: $item keeps its run, and advance.sh $item raises it again"
}

# state_not_recorded <what>: stops with the run kept, for a state write the tracker did not take.
state_not_recorded() {
  die "cannot record $1 on $item: it keeps its run, and advance.sh $item applies the step again"
}

# write_through_temp <file> <text>: writes <text> to <file> through a temp file; false when it cannot.
write_through_temp() {
  write_through_temp_file="$(mktemp "$1.XXXXXX")" || return 1
  if printf '%s\n' "$2" > "$write_through_temp_file" && mv "$write_through_temp_file" "$1"; then return 0; fi
  rm -f "$write_through_temp_file"; return 1
}

# keep_in_run <key> <value>: records <value> under <key> in the run, where a retry reads it.
keep_in_run() {
  keep_in_run_json="$(json_set "$run" "$1" "$(json_string "$2")")" || die "cannot write $run_file"
  write_through_temp "$run_file" "$keep_in_run_json" || die "cannot write $run_file"
}

# remember_asked <gate>: records that this step asked <gate> itself, before the gate is raised.
remember_asked() {
  mkdir -p "$home/asked" || die "cannot create $home/asked"
  write_through_temp "$asked_file" "$step $1" || die "cannot record in $asked_file that step $step asked the $1 gate"
}

# hold_behind <holder> <reason>: holds the item behind <holder>; false when hold.sh refuses the holder.
hold_behind() {
  "$FLOW_PLUGIN/scripts/hold.sh" set "$item" "$1" "$2"; hold_behind_code=$?
  [ "$hold_behind_code" -ne "$HOLD_NOT_WRITTEN" ] || state_not_recorded "the hold behind $1"
  [ "$hold_behind_code" -eq 0 ]
}

escalate_unopened_epic_pull_request() {
  "$FLOW_PLUGIN/scripts/gate.sh" raise "$item" escalation "**The closeout passed, but the epic's pull request could not be opened. Open it, then clear the gate.**

$(cat "$reports/epic-pr.err")" >/dev/null || gate_not_recorded escalation
  report 4 "" escalation
}

close_epic_with_nothing_to_merge() {
  [ "$(json_get "$data" status)" != closed ] || return 0
  adapter close "$item" --comment "Closed by flow: every task is closed and the closeout passed." >/dev/null 2>&1 && return 0
  "$FLOW_PLUGIN/scripts/gate.sh" raise "$item" escalation "**The closeout passed, but the tracker refused to close the epic. Clear the gate to run the closeout again, or close the epic by hand.**" >/dev/null \
    || gate_not_recorded escalation
  report 4 "" escalation
}

wait_for_the_merge_of() {
  adapter comment "$item" --body "Step $step done: ${summary:-no summary}. The epic's pull request: $1." >/dev/null
  "$FLOW_PLUGIN/scripts/gate.sh" raise "$item" merge "**$(json_get "$profiles" "gates.merge.asks")**

$1 brings the epic's branch into its base. ${summary:-$step done.}" "$step" \
    -- "step=done" "profile=$profile" "attempts=0" "last_event=$(now_iso) $step done; $1 waits for the merge" >/dev/null \
    || gate_not_recorded merge
  finish_run
  report 4 "done" merge
}

close_out_epic() {
  epic_pull_request="$("$FLOW_PLUGIN/scripts/epic-pr.sh" "$item" "$reports" "$summary" 2>"$reports/epic-pr.err")" || escalate_unopened_epic_pull_request
  rm -f "$reports/epic-pr.err"
  if [ -z "$epic_pull_request" ]; then close_epic_with_nothing_to_merge; else wait_for_the_merge_of "$epic_pull_request"; fi
}

close_item_with_nothing_to_merge() {
  adapter close "$item" --comment "Closed by flow: the pr step opened no pull request, and the branch has no change against $1, so there is nothing to merge. ${summary:-$step done.}" >/dev/null 2>&1 && return 0
  "$FLOW_PLUGIN/scripts/gate.sh" raise "$item" escalation "**The pr step opened no pull request and the branch has nothing to merge, but the tracker refused to close the item. Clear the gate to run the pr step again, or close the item by hand.**

${summary:-$step done.}" ${resized:+--} ${resized:+"$resized"} ${resized:+"profile=$profile"} >/dev/null || gate_not_recorded escalation
  report 4 "" escalation
}

close_with_nothing_to_merge() {
  [ "$(json_get "$data" status)" = closed ] || close_item_with_nothing_to_merge "$1"
  step_write "$item" "step=done" "profile=$profile" "attempts=0" ${resized:+"$resized"} "last_event=$(now_iso) $step done; no pull request and nothing to merge, closed" >/dev/null \
    || state_not_recorded "step done"
  finish_run
  "$FLOW_PLUGIN/scripts/steward.sh" release "$wt" >/dev/null || echo "advance: could not release $wt for $item" >&2
  report 6 "done" ""
}

escalate_unopened_pull_request() {
  "$FLOW_PLUGIN/scripts/gate.sh" raise "$item" escalation "**The pr step opened no pull request, but $1 has changes against $2, committed or not. Clear the gate to run the pr step again, or close the item by hand if nothing should merge.**

${summary:-$step done.}" ${resized:+--} ${resized:+"$resized"} ${resized:+"profile=$profile"} >/dev/null || gate_not_recorded escalation
  report 4 "" escalation
}

link_branch_pull_request() {
  adapter link-pr "$item" "$1" >/dev/null || echo "advance: could not record $1 on $item" >&2
}

# settle_unrecorded_pull_request: for a pr step done with no PR in its result or on the item, records
# the PR the task branch has, closes the item when there is nothing to merge, or escalates.
settle_unrecorded_pull_request() {
  [ -z "$(json_get "$result" pr)$(state_get "$data" pr)" ] || return 0
  task_branch="$(claim_name "$wt" branch)" || return 0
  item_base="$(checked_name "$(state_get "$data" base)")" || item_base="$(recorded_base "$wt")"
  settlement="$(pull_request_settlement "$home" "$wt" "$task_branch" "$item_base")"
  case "$settlement" in
    found\ *) link_branch_pull_request "${settlement#found }" ;;
    nothing-to-merge) close_with_nothing_to_merge "$item_base" ;;
    unopened) escalate_unopened_pull_request "$task_branch" "$item_base" ;;
  esac
}

size_index() { i=0; for s in $(json_list "$profiles" sizes); do [ "$s" = "$1" ] && { printf '%s' "$i"; return; }; i=$((i + 1)); done; printf '%s' -1; }

report() {
  # report <exit> <next-step> <gate>
  if [ "$as_json" -eq 1 ]; then json_obj "item=$item" "step=$step" "status=$status" "next_step=$2" "gate=$3" "profile=$profile" "size=$size" "attempts:=$attempts"; echo
  else echo "advance: $item - $step $status -> ${2:-$3}"; fi
  exit "$1"
}

[ -z "$touches" ] || adapter write-state "$item" "touches=$touches" >/dev/null || state_not_recorded "the touches"
resized=""

# The sync step runs ahead of the item's own step and never moves it: done drops the merge order,
# a gate or a failure stops at a gate, and the order stays for the run after it clears.
if [ "$step" = sync ]; then
  own="$(state_get "$data" step)"
  case "$status" in
    done)
      rm -f "$reports/sync.md"
      step_write "$item" "step=$own" "last_event=$(now_iso) sync done -> $own" >/dev/null
      adapter comment "$item" --body "The task branch is in step: ${summary:-merged}. Next: $own." >/dev/null
      finish_run
      report 0 "$own" "" ;;
    gate)
      [ -n "$gate" ] || gate="ambiguity"
      raise_asked "$gate" "${message:-$summary}"
      report 4 "" "$gate" ;;
    fail|lost)
      "$FLOW_PLUGIN/scripts/gate.sh" raise "$item" escalation "The sync step could not merge into the task branch: ${summary:-no summary}" >/dev/null \
        || gate_not_recorded escalation
      report 4 "" escalation ;;
    *) die "unknown status '$status' (done, fail, gate or lost)" 2 ;;
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
# for is raised first; on the decomposition gate the owner can still keep it whole. Only a step
# done or at the decomposition gate splits: an ambiguity or plan-approval gate means the plan is
# not settled. An item the owner kept whole stays whole until the plan is rewritten.
if [ "$step" = plan ] && { [ "$status" = done ] || { [ "$status" = gate ] && [ "$gate" = decomposition ]; }; } &&
   [ "$(json_get "$data" open_children)" -gt 0 ] 2>/dev/null &&
   grep -qiE '^Decomposition:[[:space:]]*tracker tasks' "$reports/plan.md" 2>/dev/null &&
   ! "$FLOW_PLUGIN/scripts/steward.sh" kept-whole "$item" 2>/dev/null; then
  if [ "$status" = gate ]; then
    hint=" To keep it whole instead, close its children, then clear the gate: the plan step runs again."
    raise_asked "$gate" "${message:-$summary}$hint"
  else
    gate=""; finish_run
  fi
  "$FLOW_PLUGIN/scripts/steward.sh" split "$item" >/dev/null 2>&1 || true
  report 4 split "$gate"
fi

# The plan step's changes (the globs among its touches whose existing behavior it changes) and
# its hold. Only a plan that is done holds the item; a gate means the plan is not settled.
if [ "$step" = plan ] && [ -n "$result" ]; then
  adapter write-state "$item" "changes=$(json_list "$result" changes | tr '\n' ',' | sed 's/,$//')" >/dev/null \
    || state_not_recorded "the plan's changes"
  if [ "$status" = done ]; then
    holder="$(json_get "$result" hold.behind)"
    if [ -n "$holder" ] && hold_behind "$holder" "$(json_get "$result" hold.reason)"; then
      summary="${summary:-plan done.}

Held behind $holder: $(json_get "$result" hold.reason). It starts once $holder closes."
    elif [ -z "$holder" ] && [ -n "$(state_get "$data" held_by)" ]; then
      "$FLOW_PLUGIN/scripts/hold.sh" clear "$item" "replanned with no hold on $(state_get "$data" held_by)" \
        || state_not_recorded "the lifted hold"
    fi
  fi
fi

case "$status" in
  gate)
    [ -n "$gate" ] || gate="ambiguity"
    remember_asked "$gate"
    raise_asked "$gate" "${message:-$summary}"
    step_write "$item" "step=$step" >/dev/null
    report 4 "" "$gate" ;;
  fail|lost)
    rm -f "$asked_file"
    # A verify run that was stopped (its limit, a signal, a run that died: the report's `stopped`)
    # failed no check, so no step has anything to fix: the item stays at verify, no attempt is
    # counted, and the owner decides at the gate. The run after the clear reuses every test
    # command that passed.
    if [ "$step" = verify ] && [ -n "$(json_get "$result" stopped)" ]; then
      "$FLOW_PLUGIN/scripts/gate.sh" raise "$item" escalation "**Verify did not finish, and no check failed. Give it room, then clear the gate to run it again.**

- What happened: $(json_get "$result" checks.0.summary).
- A check that needs longer: raise \`verify.limit\` in \`.flow/config.yaml\`. A busy machine: clear the gate once it is free.
- The next run reuses every test command that already passed." >/dev/null || gate_not_recorded escalation
      report 4 "" escalation
    fi
    attempts=$((attempts + 1))
    max="$(json_get "$profiles" max_attempts)"
    if [ "$attempts" -ge "${max:-3}" ]; then
      "$FLOW_PLUGIN/scripts/gate.sh" raise "$item" escalation "Step $step failed $attempts times. Last: ${summary:-no summary}" \
        -- "attempts=$attempts" >/dev/null || gate_not_recorded escalation
      report 4 "" escalation
    fi
    fix="$(json_get "$profiles" "fix_step.$step")"; [ -n "$fix" ] || fix="$step"
    [ "$status" != lost ] || fix="$step"
    step_write "$item" "step=$fix" "attempts=$attempts" "last_event=$(now_iso) $step failed (attempt $attempts): ${summary:-no summary}" >/dev/null \
      || state_not_recorded "attempt $attempts of step $step"
    adapter comment "$item" --body "Step $step failed (attempt $attempts of ${max:-3}): ${summary:-no summary}. Back to $fix." >/dev/null
    finish_run
    report 0 "$fix" "" ;;
  done) ;;
  *) die "unknown status '$status' (done, fail, gate or lost)" 2 ;;
esac
step_asked="$(json_get "$run" asked)"
[ -n "$step_asked" ] || step_asked="$(cat "$asked_file" 2>/dev/null)"
[ -z "$step_asked" ] || keep_in_run asked "$step_asked"
rm -f "$asked_file"

# done: a passing verify that touched rendered code raises the feel-test gate after moving on.
feel_test=0
[ "$step" = "$(json_get "$profiles" feel_test_step)" ] && [ "$(json_get "$result" feel_test)" = "true" ] && feel_test=1
# re-size at the step boundary, then move on. An epic has no size: every size selects the one
# epic profile and next.sh clears the size it starts with, so a size its step names re-sizes nothing.
next_profile="$profile"
if [ "$kind" != epic ] && [ -n "$new_size" ] && [ "$new_size" != "$size" ]; then
  old_i="$(size_index "$size")"; new_i="$(size_index "$new_size")"
  [ "$new_i" -ge 0 ] || die "unknown size $new_size" 2
  if [ $((new_i - old_i)) -ge 2 ] || { [ "$new_size" = "L" ] && [ "$new_i" -gt "$old_i" ]; }; then
    "$FLOW_PLUGIN/scripts/gate.sh" raise "$item" plan-approval "**Re-sized $size -> $new_size at step $step. Replan or split, then clear the gate.**

${summary:-No summary.}" -- "size=$new_size" "step=$step" "profile=$(profile_select "$kind" "$new_size")" >/dev/null \
      || gate_not_recorded plan-approval
    size="$new_size"; report 4 "" plan-approval
  fi
  resized="size=$new_size"
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
[ "$step" != closeout ] || [ "$kind" != epic ] || close_out_epic
if [ -z "$following" ]; then
  step_write "$item" "step=done" "profile=$profile" "attempts=0" ${resized:+"$resized"} "last_event=$(now_iso) $step done; every step ran" >/dev/null \
    || state_not_recorded "step done"
  adapter comment "$item" --body "Step $step done: ${summary:-no summary}. Every step of $profile ran." >/dev/null
  finish_run
  report 6 "done" ""
fi
[ "$step" != pr ] || [ "$following" != gate:merge ] || settle_unrecorded_pull_request
case "$following" in
  gate:*)
    g="${following#gate:}"
    after="$(profile_steps "$profile" | awk -v s="$following" 'f {print; exit} $0 == s {f = 1}')"
    [ -n "$after" ] || after="done"
    # The step asked this gate itself and the owner answered it, not sent it back: the answer
    # stands, and the gate is not raised a second time for the same step.
    if [ "$step_asked" = "$step $g" ] && case "$(state_get "$data" answered)" in "$g"|"$g, option "*) true ;; *) false ;; esac; then
      step_write "$item" "step=$after" "profile=$profile" "attempts=0" ${resized:+"$resized"} "last_event=$(now_iso) $step done; gate $g answered at the step" >/dev/null \
        || state_not_recorded "step $after"
      adapter comment "$item" --body "Step $step done: ${summary:-no summary}. The owner answered the $g gate at this step, so it is not asked again. Next: $after." >/dev/null
      printf '%s\t%s\t%s\t%s\n' "$(now_iso)" "$item" "$g" "not asked again: the owner answered it at step $step" >> "$home/events.log"
      finish_run
      report 0 "$after" ""
    fi
    # auto_gates: only plan-approval can be cleared by the flow, by item size; every other gate waits.
    if [ "$g" = "plan-approval" ] && case ",$(cfg auto_gates.plan-approval | tr -d ' ')," in *",$size,"*) true ;; *) false ;; esac; then
      step_write "$item" "step=$after" "profile=$profile" "attempts=0" ${resized:+"$resized"} "last_event=$(now_iso) $step done; gate $g auto-approved (size $size)" >/dev/null \
        || state_not_recorded "step $after"
      adapter comment "$item" --body "Step $step done: ${summary:-no summary}. Gate $g auto-approved by auto_gates for size $size. Next: $after." >/dev/null
      printf '%s\t%s\t%s\t%s\n' "$(now_iso)" "$item" "$g" "auto-approved (size $size)" >> "$home/events.log"
      finish_run
      report 0 "$after" ""
    fi
    # The ask leads, in bold, so the owner reads the decision before the step's summary.
    "$FLOW_PLUGIN/scripts/gate.sh" raise "$item" "$g" "**$(json_get "$profiles" "gates.$g.asks")**

${summary:-$step done.}" "$step" -- "step=$after" "profile=$profile" "attempts=0" ${resized:+"$resized"} "last_event=$(now_iso) $step done; gate $g" >/dev/null \
      || gate_not_recorded "$g"
    report 4 "$after" "$g" ;;
  *)
    moved_on="last_event=$(now_iso) $step done -> $following"
    adapter comment "$item" --body "Step $step done: ${summary:-no summary}. Next: $following." >/dev/null
    if [ "$feel_test" -eq 1 ]; then
      # Problems the owner reports go back to the step that writes the code, not to verify.
      back="$(json_get "$profiles" "fix_step.$step")"
      "$FLOW_PLUGIN/scripts/gate.sh" raise "$item" feel-test "**$(json_get "$profiles" "gates.feel-test.asks")**

Verify passed and the change touches rendered code. What to launch and what to look for: \`$reports/verify.md\`. Signing off continues with $following." "${back:-$step}" \
        -- "step=$following" "profile=$profile" "attempts=0" ${resized:+"$resized"} "$moved_on" >/dev/null || gate_not_recorded feel-test
      report 4 "$following" feel-test
    fi
    step_write "$item" "step=$following" "profile=$profile" "attempts=0" ${resized:+"$resized"} "$moved_on" >/dev/null \
      || state_not_recorded "step $following"
    finish_run
    report 0 "$following" "" ;;
esac
