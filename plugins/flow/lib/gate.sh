#!/bin/sh
# Gate helpers for scripts/gate.sh, sourced after lib/flow.sh and lib/host.sh with $home set: who
# carries an answer out, the fields and footer a raise records, and one clear_* function per kind
# of clear. A clear_* function acts on the clear in hand, which gate.sh reads once the item's
# clear lock is held: item, record (the record's path), record_json, asked, gate, step, from, pr.

CLEAR_LOCK_WAIT_SECONDS=10
EXIT_BUSY=75
CARRIER_SWEEP=sweep
CARRIER_STEP=step
CARRIER_CHILDREN=children
CARRIER_COMMENTS=comments
CARRIER_OWNER=owner
PENDING_UNACTED=unacted
FIELD_ANSWERED_BY=1
FIELD_PENDING=2
FIELD_HOW_TO_CLEAR=3
FIRST_STEP_ANSWERER="the first step, when next starts the item"

# step_runs <step>: next.sh runs it: a profile step, or the first one of an item not started.
step_runs() { [ -z "$1" ] || [ -n "$(json_get "$(cat "$FLOW_PLUGIN/profiles.json")" "steps.$1")" ]; }

# read_pr_state <pr>: the PR's state as comments.sh reads it (OPEN, MERGED, CLOSED); nothing when
# it cannot be read.
read_pr_state() {
  pr_view="$("$FLOW_PLUGIN/scripts/comments.sh" state "$1" 2>/dev/null)" && json_get "$pr_view" state 2>/dev/null
}

# done_carrier <pr>: who carries an answer out at done with a PR: the comments job on an open
# one, or one it cannot read (the job logs why it skips it); the owner on a merged or closed one.
done_carrier() {
  case "$(read_pr_state "$1")" in ""|OPEN) echo "$CARRIER_COMMENTS" ;; *) echo "$CARRIER_OWNER" ;; esac
}

# carrier_kind <step> <gate> <pr>: who carries an answer to the gate out. The merge gate's answer
# is the merge itself (the sweep); next runs a step it knows; a split leaves the work to its
# children; at done with a PR, done_carrier. Anything else no step acts on: the owner does it by hand.
carrier_kind() {
  if [ "$2" = merge ]; then echo "$CARRIER_SWEEP"
  elif step_runs "$1"; then echo "$CARRIER_STEP"
  elif [ "$1" = split ] && [ "$2" = decomposition ]; then echo "$CARRIER_CHILDREN"
  elif [ "$1" = done ] && [ -n "$3" ]; then done_carrier "$3"
  else echo "$CARRIER_OWNER"; fi
}

# step_answerer <step>: the step that carries the answer out, as the record names it.
step_answerer() { if [ -n "$1" ]; then printf 'step %s' "$1"; else printf '%s' "$FIRST_STEP_ANSWERER"; fi; }

# carrier_fields <answered by> <pending> <how to clear>: one tab-separated carrier row.
carrier_fields() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }

# carrier_field <row> <field>: one field of a carrier row (FIELD_ANSWERED_BY, FIELD_PENDING or
# FIELD_HOW_TO_CLEAR).
carrier_field() { printf '%s\n' "$1" | cut -f "$2"; }

# carrier_row <kind> <item> <step> <option hint>: the one table of carriers. Each kind's row: who
# the record names as answering (answered_by), what the answer waits on (answer_pending: nothing
# for the merge or a split left standing, PENDING_UNACTED when no step acts on it) and the line
# of the gate's footer that says how to clear it.
carrier_row() {
  case "$1" in
    "$CARRIER_SWEEP") carrier_fields "the sweep, once the PR merges" "" \
      "Merge the PR: the sweep clears this gate once it merges." ;;
    "$CARRIER_CHILDREN") carrier_fields "nobody: the children carry the work" "" \
      "The children carry the work: \`gate.sh clear $2\` lets the split stand; close the children first to keep it whole." ;;
    "$CARRIER_COMMENTS") carrier_fields "comments job, next pass" comments \
      "Answered by the comments job on its next pass; answer: \`gate.sh clear $2 \"<answer>\"\`$4." ;;
    "$CARRIER_OWNER") carrier_fields "nobody: do it by hand, then clear with no answer" "$PENDING_UNACTED" \
      "No step acts on an answer: do it by hand, then \`gate.sh clear $2\`." ;;
    "$CARRIER_STEP") carrier_fields "$(step_answerer "$3")" next \
      "Answered by $(step_answerer "$3"); answer: \`gate.sh clear $2 \"<answer>\"\`$4." ;;
  esac
}

# raised_by_default <flag> <item> <step>: who raised the gate: the --raised-by flag, else the step
# of the run in flight (its record goes once the gate raises), else the item's step, else the owner.
raised_by_default() {
  run_record="$home/runs/$(item_slug "$2").json"; run_step=""
  [ -f "$run_record" ] && run_step="$(json_get "$(cat "$run_record")" step)"
  if [ -n "$1" ]; then printf '%s' "$1"
  elif [ -n "$run_step" ]; then printf 'step %s' "$run_step"
  elif [ -n "$3" ]; then printf 'step %s' "$3"
  else printf 'owner'; fi
}

# raise_options <item> <options>: the options as _gates.py normalises them, else [] with the
# reason on stderr: the agent that wrote them is gone, and a gate without buttons beats no gate.
raise_options() {
  [ -n "$2" ] || { echo "[]"; return 0; }
  if normalised="$(python3 -I "$FLOW_PLUGIN/scripts/_gates.py" options "$2" 2>&1)"; then printf '%s\n' "$normalised"; return 0; fi
  echo "flow: $1: --options dropped ($normalised); the gate raises without options" >&2
  echo "[]"
}

# raise_condition <item> <condition>: the condition when it is in the grammar, else nothing, with
# a warning on stderr; the gate raises either way.
raise_condition() {
  [ -n "$2" ] || return 0
  if condition_in_grammar "$2"; then printf '%s' "$2"; return 0; fi
  echo "flow: $1: --condition dropped (\"$2\" is not blocked_by:<id of an item an adapter owns>, pr:#<n> conflicting or ci:down); the gate raises without it" >&2
}

# option_hint <options>: the footer's note that an option answers too, when the gate has options.
option_hint() { [ "$1" = "[]" ] || printf ' (or `--option N`)'; }

# condition_footer <condition>: the footer's line on what the gate waits on, when it has a
# condition: the health job clears it once that ends.
condition_footer() {
  condition_pr="${1#pr:}"
  case "$1" in
    blocked_by:*) printf 'Clears itself once %s closes (the health job checks each pass). ' "${1#blocked_by:}" ;;
    pr:*) printf 'Clears itself once PR %s no longer conflicts (the health job checks each pass). ' "${condition_pr% conflicting}" ;;
    ci:down) printf 'Clears itself once CI no longer fails (the health job checks each pass). ' ;;
  esac
}

# gate_footer <condition> <how to clear>: the paragraph under the gate's message on the tracker
# and in the notification: what clears the gate and the exact command (the carrier row's line),
# so an owner on a host without the gate record still has it.
gate_footer() { printf '%s%s' "$(condition_footer "$1")" "$2"; }

# lock_gate_clears <item>: holds the item's clear lock until gate.sh exits, so the owner and the
# health job never clear one gate twice: the second reads the record after the first removed it.
# Dies, exit EXIT_BUSY, when another clear held it over CLEAR_LOCK_WAIT_SECONDS.
lock_gate_clears() {
  FLOW_LOCK_WAIT="$CLEAR_LOCK_WAIT_SECONDS" flow_lock "gate-$(item_slug "$1")" \
    || die "another clear of $1 has held its gate for over ${CLEAR_LOCK_WAIT_SECONDS}s; try again" "$EXIT_BUSY"
}

# picked_option_answer <n> <note>: the answer option n of the record stands for: its text, then
# the note as a second paragraph. Dies, exit 2, with no record on this host, no options, or n out
# of range.
picked_option_answer() {
  [ -n "$record_json" ] || die "$item has no gate record on this host: the record lives in the flow home of the host that raised the gate. Pick the option there, or answer in words: gate.sh clear $item \"<answer>\"" 2
  option_count="$(json_length "$record_json" options)"
  [ "$option_count" -gt 0 ] || die "the ${gate:-gate} gate on $item has no options recorded; answer in words: gate.sh clear $item \"<answer>\"" 2
  picked="$1"; case "$picked" in ''|0*|*[!0-9]*) picked=0 ;; esac
  [ "$picked" -ge 1 ] && [ "$picked" -le "$option_count" ] \
    || die "the ${gate:-gate} gate on $item has options 1 to $option_count; --option takes one of them" 2
  picked_text="$(json_get "$record_json" "options.$((picked - 1)).text")"
  [ -n "$2" ] || { printf '%s' "$picked_text"; return 0; }
  printf '%s\n\n%s' "$picked_text" "$2"
}

# refuse_unacted_answer: dies, exit 1, with what the owner does instead: no step acts on an answer
# to this gate, so the gate stays rather than drop the answer in silence.
refuse_unacted_answer() {
  [ "$step" != done ] || [ -z "$pr" ] || die "no step acts on this answer: $item is done and its PR $pr is $(read_pr_state "$pr" | tr '[:upper:]' '[:lower:]'), so no comments pass would carry it out. Do it by hand, then clear the gate with no answer (gate.sh clear $item). The ${gate:-gate} gate stays."
  send_back_hint=""; [ -n "$from" ] && step_runs "$from" && send_back_hint=", or send it back to $from: gate.sh clear $item --back \"<what to change>\""
  die "no step acts on this answer: $item is at step ${step:-none} with no PR, so no run would carry it out. Do it by hand, then clear the gate with no answer (gate.sh clear $item)$send_back_hint. The ${gate:-gate} gate stays."
}

# answer_pending_for <answer>: who the answer waits on in answer_pending until a run takes it (the
# board shows it): next, when the item's step is one it runs; comments, at done with an open PR.
# Nothing for the merge gate (the merge is the answer), a split left standing, or a clear with no
# answer where no step runs. Dies through refuse_unacted_answer when no step acts on the answer.
answer_pending_for() {
  [ -n "$1" ] || step_runs "$step" || return 0
  carrier="$(carrier_row "$(carrier_kind "$step" "$gate" "$pr")" "$item" "$step" "")"
  pending="$(carrier_field "$carrier" "$FIELD_PENDING")"
  [ "$pending" != "$PENDING_UNACTED" ] || refuse_unacted_answer
  printf '%s' "$pending"
}

# release_hosts_stopped_for <item>: a host this item's gate stopped on a spend limit or an auth
# error (lib/host.sh) starts sessions again; one line for each.
release_hosts_stopped_for() {
  for stopped_host in claude codex; do
    stop_file="$(host_stop_file "$stopped_host")"
    [ -f "$stop_file" ] && [ "$(json_get "$(cat "$stop_file")" item)" = "$1" ] && rm -f "$stop_file" && echo "$stopped_host starts sessions again"
  done
  return 0
}

# log_answered <item> <line>: one events.log line per answer, so the console can list what was
# answered today.
log_answered() {
  mkdir -p "$home"
  printf '%s\t%s\tanswered\t%s\n' "$(now_iso)" "$1" "$(printf '%s' "$2" | tr '\n' ' ')" >> "$home/events.log"
}

# keep_whole_when_children_closed: the split happened when the plan step ended (advance.sh), and
# clearing the gate never splits; an owner who closed a split's children before clearing its
# decomposition gate keeps the item whole, and its plan step runs again. 0 when it did, 1 when
# the split stands or the gate is another one.
keep_whole_when_children_closed() {
  [ "$gate" = decomposition ] || return 1
  item_now="$(adapter read "$item" 2>/dev/null)"
  [ "$(state_get "$item_now" step)" = split ] && [ "$(json_get "$item_now" open_children)" = 0 ] || return 1
  step_write "$item" "step=plan" "answer_pending=next" "last_event=$(now_iso) kept whole: the children are closed, the plan step runs again" >/dev/null
  "$FLOW_PLUGIN/scripts/steward.sh" keep-whole "$item" >/dev/null
  echo "gate cleared on $item; its children are closed, so it is whole again: next $item runs the plan step"
}

# clear_with_answer <answer> <answered as> <answered line> <pending>: the gate clears with the
# owner's answer. The question and the answer stay in the state, so the next step's brief carries
# them; answered_at stays too: the comments job counts a clear as new activity on the item's PR.
clear_with_answer() {
  cleared_at="$(now_iso)"
  adapter write-state "$item" "gate=none" "gate_from=" "attempts=0" "answered=$2" "asked=$asked" "answer=$1" \
    "answered_at=$cleared_at" "answer_pending=$4" "last_event=$cleared_at gate cleared: $1" >/dev/null
  adapter comment "$item" --body "Gate cleared: $1" >/dev/null
  log_answered "$item" "$3"
  rm -f "$record"
  keep_whole_when_children_closed && return 0
  case "$4:$step" in
    comments:*) echo "gate cleared on $item; it is done, so the comments job carries the answer out on its next pass on $pr (now: jobs/comments.sh <host> $item)" ;;
    next:*|*:split) echo "gate cleared on $item; run next $item to continue" ;;
    *) echo "gate cleared on $item; nothing runs on it (step ${step:-none})" ;;
  esac
}

# clear_answer <answer>: the owner's answer in words, or none ("cleared"): it waits on the step
# that carries it out (answer_pending_for).
clear_answer() {
  answer_pending="$(answer_pending_for "$1")" || exit $?
  release_hosts_stopped_for "$item"
  clear_with_answer "${1:-cleared}" "$gate" "${gate:-gate}: ${1:-cleared}" "$answer_pending"
}

# clear_option <n> <answer>: the owner picked option n; the answer is picked_option_answer's, and
# the state and the events log name the option. On a gate that waits on blocked_by:<blocker>, a
# pick is the owner's choice not to wait for it (the pr step's "Open it now"): the blocker is
# waived (lib/blockers.sh), so next.sh and the ready filter run the step that carries the answer
# out while it is still open. An answer in words waives nothing: the item waits as before.
clear_option() {
  option_text="$(json_get "$record_json" "options.$(($1 - 1)).text")"
  option_label="$(json_get "$record_json" "options.$(($1 - 1)).label")"
  answer_pending="$(answer_pending_for "$2")" || exit $?
  waived_condition="$(json_get "$record_json" condition)"
  case "$waived_condition" in blocked_by:*) waive_blocker "$item" "${waived_condition#blocked_by:}" ;; esac
  release_hosts_stopped_for "$item"
  clear_with_answer "$2" "$gate, option $1 ($option_label)" "$gate (option $1): $option_text" "$answer_pending"
}

# clear_back <message>: the owner sends the work back: the gate's from step runs again. The
# question and the message stay in the state, so the from step's brief carries them, and
# answered_at dates the answer that waits on next (the board's Health). Dies, exit 2, when the
# gate has no from step or the item is split; exit 1 when no run does the from step again.
clear_back() {
  [ -n "$from" ] || die "$item has no step to send back to (its gate predates gate_from); clear it with the change instead" 2
  [ "$step" != split ] || die "$item is already split into tracker tasks; close its children to keep it whole, then clear the gate" 2
  step_runs "$from" || die "$item has no step to send back to: its ${gate:-gate} gate judges the $from step, which no run does again. Do it by hand, then clear the gate with no answer: gate.sh clear $item"
  release_hosts_stopped_for "$item"
  sent_at="$(now_iso)"
  step_write "$item" "gate=none" "gate_from=" "step=$from" "attempts=0" "answered=$gate, sent back" "asked=$asked" "answer=$1" \
    "answered_at=$sent_at" "answer_pending=next" "last_event=$sent_at gate sent back to $from: $1" >/dev/null
  adapter comment "$item" --body "Gate sent back to $from: $1" >/dev/null
  log_answered "$item" "${gate:-gate}, sent back to $from: $1"
  rm -f "$record"
  echo "gate sent back on $item; run next $item to run $from again"
}

# clear_met <condition>: the gate clears because the condition it waits on ended (the health
# job): not the owner's answer, so no answered line and nothing pending; the item keeps its step,
# so the next pass runs it.
clear_met() {
  release_hosts_stopped_for "$item"
  met_note="$1 no longer holds"; met_at="$(now_iso)"
  adapter write-state "$item" "gate=none" "gate_from=" "attempts=0" "answered=$gate, condition met" "asked=$asked" "answer=$met_note" \
    "answer_pending=" "last_event=$met_at gate cleared by health: $met_note" >/dev/null
  adapter comment "$item" --body "Gate cleared by the health job: $met_note" >/dev/null
  rm -f "$record"
  step_runs "$step" && { echo "gate cleared on $item: $met_note; run next $item to continue"; return 0; }
  echo "gate cleared on $item: $met_note; nothing runs on it (step ${step:-none})"
}
