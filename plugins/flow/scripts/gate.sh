#!/bin/sh
# Human gates.
#   gate.sh raise <item> <gate> <message> [<from step>] [--options <json>] [--condition <text>]
#                 [--raised-by <who>]       record the gate in the tracker, notify, stop the run;
#                                           <from step> is the step whose work the gate judges
#                                           (default: the item's step now), where --back returns.
#                                           --options: a JSON array of 1 to 9 {label, text,
#                                           recommended}, at most one recommended; --condition:
#                                           blocked_by:<item>, pr:#<n> conflicting or ci:down, what
#                                           the gate waits on; --raised-by: who asks (default: the
#                                           step of the run in flight, else the item's step, else
#                                           owner). A malformed --options or --condition is dropped
#                                           with a warning and the gate still raises. The record
#                                           keeps who carries the answer out and a footer with the
#                                           command, which the tracker comment and the notification
#                                           carry under the message
#   gate.sh clear <item> [<message>]        the owner's answer: gate back to none, run can resume;
#                                           on the decomposition gate of a split task whose
#                                           children are all closed, the plan step runs again;
#                                           a host the gate stopped starts sessions again. The
#                                           answer waits (answer_pending) on next, or at done
#                                           with an open PR on the comments job; an answer no
#                                           step acts on (done, no open PR) fails, exit 1, and
#                                           the gate stays
#   gate.sh clear <item> --back <message>   the owner sends the work back: the gate's from step
#                                           runs again, with the message in its brief; exit 1
#                                           when no run does that step again (done)
#   gate.sh clear <item> --option <n> [<note>]
#                                           the owner picks option n of the gate record: its text
#                                           is the answer, the note a second paragraph under it;
#                                           exit 2 with no record on this host, no options, n out
#                                           of range, or with --back
#   gate.sh clear <item> --met <note>       the gate's condition no longer holds (the health job):
#                                           nothing waits on a run, the item keeps its step; exit 2
#                                           when the gate has no condition; "already cleared",
#                                           exit 0, when its record is gone
#                                           Each clear of an item waits for another one to finish
#                                           (exit 75 after 10s) and reads the record after it
#   gate.sh clear <claude|codex>            start sessions on a host a spend limit or an auth
#                                           error stopped outside any item's run
#   gate.sh list [--json]                   pending gates; --json prints one array, oldest first,
#                                           with the claimed worktree, the age, the questions, the
#                                           options, who raised it, who answers it, its condition
#                                           and its footer
# Gates: interview, plan-approval, decomposition, feel-test, merge, escalation, ambiguity.
# FLOW_NOW (an ISO time, 2026-10-25T09:00:00Z) stands in for the clock in the age. It exists for
# tests, like FLOW_HOME.
. "$(dirname "$0")/../lib/flow.sh"
home="$(flow_home)"

# gates_json: each gate record with its claimed worktree (steward.sh find) or null, through
# scripts/_gates.py, which adds the age and the parsed questions. A record that is not a JSON
# object is skipped with a warning, so one bad file never hides the other gates.
gates_json() {
  for f in "$home"/gates/*.json; do
    [ -f "$f" ] || continue
    record="$(json_set "$(cat "$f")" worktree null 2>/dev/null)"
    [ -n "$record" ] || { echo "flow: skipping $f, not a JSON gate record" >&2; continue; }
    item="$(json_get "$record" item)"; worktree=""
    [ -n "$item" ] && worktree="$("$FLOW_PLUGIN/scripts/steward.sh" find "$item")"
    if [ -n "$worktree" ]; then json_set "$record" worktree "$(json_string "$worktree")"; else printf '%s\n' "$record"; fi
  done | python3 -I "$FLOW_PLUGIN/scripts/_gates.py" "${FLOW_NOW:-$(now_iso)}"
}

RAISE_USAGE="usage: gate.sh raise <item> <gate> <message> [<from step>] [--options <json>] [--condition <text>] [--raised-by <who>]"
CLEAR_USAGE="usage: gate.sh clear <item> [<message>] | gate.sh clear <item> --back <message> | gate.sh clear <item> --option <n> [<note>] | gate.sh clear <item> --met <note>"
# How long a clear waits for another clear of the same item to finish.
CLEAR_LOCK_SECONDS=10
# Who carries an answer out, as the record and the console name it.
CARRIER_SWEEP="the sweep, once the PR merges"
CARRIER_CHILDREN="nobody: the children carry the work"
CARRIER_COMMENTS="comments job, next pass"
CARRIER_OWNER="nobody: do it by hand, then clear with no answer"
CARRIER_FIRST_STEP="the first step, when next starts the item"

# step_runs <step>: next.sh runs it: a profile step, or the first one of an item not started.
# json_get prints nothing for a missing key, and exits 0 either way.
step_runs() { [ -z "$1" ] || [ -n "$(json_get "$(cat "$FLOW_PLUGIN/profiles.json")" "steps.$1")" ]; }

# read_pr_state <pr>: the PR's state as comments.sh reads it (OPEN, MERGED, CLOSED); nothing when
# it cannot be read.
read_pr_state() {
  pr_view="$("$FLOW_PLUGIN/scripts/comments.sh" state "$1" 2>/dev/null)" && json_get "$pr_view" state 2>/dev/null
}

# answer_carrier <step> <gate> <pr>: who carries an answer to the gate out. The merge gate's
# answer is the merge itself; next runs a step it knows; a split leaves the work to its children;
# at done with a PR, the comments job passes on an open one, or one it cannot read (the job logs
# why it skips it). Anything else no step acts on: the owner does it by hand.
answer_carrier() {
  if [ "$2" = merge ]; then echo "$CARRIER_SWEEP"
  elif step_runs "$1"; then if [ -n "$1" ]; then echo "step $1"; else echo "$CARRIER_FIRST_STEP"; fi
  elif [ "$1" = split ] && [ "$2" = decomposition ]; then echo "$CARRIER_CHILDREN"
  elif [ "$1" = done ] && [ -n "$3" ]; then
    case "$(read_pr_state "$3")" in ""|OPEN) echo "$CARRIER_COMMENTS" ;; *) echo "$CARRIER_OWNER" ;; esac
  else echo "$CARRIER_OWNER"; fi
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

# condition_in_grammar <condition>: 0 when it is one the health job reads: blocked_by:<item>,
# pr:#<n> conflicting or ci:down.
condition_in_grammar() {
  condition_pr="${1#pr:#}"; condition_pr="${condition_pr% conflicting}"
  case "$1" in
    ci:down) return 0 ;;
    blocked_by:*) case "${1#blocked_by:}" in ""|*[[:space:]]*) return 1 ;; esac ;;
    "pr:#"*" conflicting") case "$condition_pr" in ""|*[!0-9]*) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  return 0
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
  echo "flow: $1: --condition dropped (\"$2\" is not blocked_by:<item>, pr:#<n> conflicting or ci:down); the gate raises without it" >&2
}

# gate_footer <item> <carrier> <condition> <options>: the paragraph under the gate's message on
# the tracker and in the notification: what clears the gate and the exact command, so an owner on
# a host without the gate record still has it.
gate_footer() {
  footer_option=""; [ "$4" = "[]" ] || footer_option=" (or \`--option N\`)"
  footer_pr="${3#pr:}"; footer_pr="${footer_pr% conflicting}"
  case "$3" in
    blocked_by:*) printf 'Clears itself once %s closes (the health job checks each pass). ' "${3#blocked_by:}" ;;
    pr:*) printf 'Clears itself once PR %s no longer conflicts (the health job checks each pass). ' "$footer_pr" ;;
    ci:down) printf 'Clears itself once CI no longer fails (the health job checks each pass). ' ;;
  esac
  case "$2" in
    "$CARRIER_SWEEP") printf 'Merge the PR: the sweep clears this gate once it merges.' ;;
    "$CARRIER_CHILDREN") printf 'The children carry the work: `gate.sh clear %s` lets the split stand; close the children first to keep it whole.' "$1" ;;
    "$CARRIER_OWNER") printf 'No step acts on an answer: do it by hand, then `gate.sh clear %s`.' "$1" ;;
    "$CARRIER_COMMENTS") printf 'Answered by the comments job on its next pass; answer: `gate.sh clear %s "<answer>"`%s.' "$1" "$footer_option" ;;
    *) printf 'Answered by %s; answer: `gate.sh clear %s "<answer>"`%s.' "$2" "$1" "$footer_option" ;;
  esac
}

case "${1:-}" in
  raise)
    [ $# -ge 4 ] || die "$RAISE_USAGE" 2
    item="$2"; gate="$3"; message="$4"; from=""; shift 4
    case "${1:-}" in --*) ;; *) [ $# -eq 0 ] || { from="$1"; shift; } ;; esac
    options_given=""; condition_given=""; raised_by_given=""
    while [ $# -gt 0 ]; do
      [ $# -ge 2 ] || die "$RAISE_USAGE" 2
      case "$1" in
        --options) options_given="$2" ;;
        --condition) condition_given="$2" ;;
        --raised-by) raised_by_given="$2" ;;
        *) die "$RAISE_USAGE" 2 ;;
      esac
      shift 2
    done
    json_get "$(cat "$FLOW_PLUGIN/profiles.json")" "gates.$gate" >/dev/null 2>&1 || true
    data="$(adapter read "$item" 2>/dev/null)"; step="$(state_get "$data" step)"
    [ -n "$from" ] || from="$step"
    options="$(raise_options "$item" "$options_given")"
    condition="$(raise_condition "$item" "$condition_given")"
    raised_by="$(raised_by_default "$raised_by_given" "$item" "$step")"
    answered_by="$(answer_carrier "$step" "$gate" "$(state_get "$data" pr)")"
    footer="$(gate_footer "$item" "$answered_by" "$condition" "$options")"
    condition_field="condition:=null"; [ -z "$condition" ] || condition_field="condition=$condition"
    adapter write-state "$item" "gate=$gate" "gate_from=$from" "last_event=$(now_iso) gate $gate" >/dev/null
    adapter comment "$item" --body "**Gate: $gate**

$message

$footer" >/dev/null
    rm -f "$home/runs/$(item_slug "$item").json"
    [ "$gate" = "escalation" ] && "$FLOW_PLUGIN/scripts/lesson.sh" escalation "$item" "$message" >/dev/null
    "$FLOW_PLUGIN/scripts/notify.sh" "$gate" "$item" "$message" "options:=$options" "raised_by=$raised_by" \
      "answered_by=$answered_by" "$condition_field" "footer=$footer" ;;
  clear)
    [ $# -ge 2 ] || die "$CLEAR_USAGE" 2
    item="$2"; mode=answer; option_number=""
    case "${3:-}" in
      --back) mode=back; shift ;;
      --option) [ $# -ge 4 ] || die "$CLEAR_USAGE" 2; mode=option; option_number="$4"; shift 2 ;;
      --met) mode=met; shift ;;
    esac
    message="${3:-cleared}"; given="${3:-}"
    case "$mode:$given" in
      back:--option|option:--back) die "gate.sh clear takes --option or --back, not both: a pick answers the gate, a send-back redoes its step" 2 ;;
      back:) die "gate.sh clear --back needs a message: what to change" 2 ;;
      met:) die "gate.sh clear --met needs a note: the condition that no longer holds" 2 ;;
    esac
    # A host stopped on a spend limit or an auth error (lib/host.sh) starts sessions again when
    # the gate that names it clears, or when the owner clears the host by name.
    . "$FLOW_PLUGIN/lib/host.sh"
    case "$item" in claude|codex)
      [ -f "$(host_stop_file "$item")" ] || { echo "$item is not stopped"; exit 0; }
      rm -f "$(host_stop_file "$item")"; echo "$item starts sessions again"; exit 0 ;;
    esac
    # One clear of an item at a time (the health job and the owner can race); the record is read
    # once the lock is held, so the second finds it gone.
    FLOW_LOCK_WAIT="$CLEAR_LOCK_SECONDS" flow_lock "gate-$(item_slug "$item")" \
      || die "another clear of $item has held its gate for over ${CLEAR_LOCK_SECONDS}s; try again" 75
    record="$home/gates/$(item_slug "$item").json"; asked=""; gate=""; record_json=""
    [ -f "$record" ] && { record_json="$(cat "$record")"; asked="$(json_get "$record_json" message)"; gate="$(json_get "$record_json" gate)"; }
    if [ "$mode" = met ]; then
      [ -n "$record_json" ] || { echo "gate already cleared on $item"; exit 0; }
      [ -n "$(json_get "$record_json" condition)" ] || die "the ${gate:-gate} gate on $item waits on no condition, so only the owner's answer clears it: gate.sh clear $item \"<answer>\"" 2
    fi
    if [ "$mode" = option ]; then
      [ -n "$record_json" ] || die "$item has no gate record on this host: the record lives in the flow home of the host that raised the gate. Pick the option there, or answer in words: gate.sh clear $item \"<answer>\"" 2
      option_count="$(json_length "$record_json" options)"
      [ "$option_count" -gt 0 ] || die "the ${gate:-gate} gate on $item has no options recorded; answer in words: gate.sh clear $item \"<answer>\"" 2
      case "$option_number" in ''|0*|*[!0-9]*) option_number=0 ;; esac
      [ "$option_number" -ge 1 ] && [ "$option_number" -le "$option_count" ] \
        || die "the ${gate:-gate} gate on $item has options 1 to $option_count; --option takes one of them" 2
      option_text="$(json_get "$record_json" "options.$((option_number - 1)).text")"
      option_label="$(json_get "$record_json" "options.$((option_number - 1)).label")"
      message="$option_text"; [ -z "$given" ] || message="$option_text

$given"
      given="$message"
    fi
    data="$(adapter read "$item" 2>/dev/null)"
    [ -n "$gate" ] || { gate="$(state_get "$data" gate)"; [ "$gate" != none ] || gate=""; }
    answered_as="$gate"; answered_line="${gate:-gate}: $message"
    [ "$mode" != option ] || { answered_as="$gate, option $option_number ($option_label)"; answered_line="$gate (option $option_number): $option_text"; }
    step="$(state_get "$data" step)"; from="$(state_get "$data" gate_from)"; pr="$(state_get "$data" pr)"
    # Who carries out the answer (answer_carrier), kept in answer_pending until a run takes it (the
    # board shows it): next, when the item's step is one it runs; the comments job, at done with an
    # open PR (a gate a comments pass raised). The merge gate's answer is the merge itself; a clear
    # with no answer, one that lets a split stand, or one because the gate's condition ended,
    # carries nothing out. Any other answer no step acts on: the clear fails and the gate stays, so
    # an answer is never dropped in silence.
    pending=""
    if [ "$mode" = back ]; then
      [ -n "$from" ] || die "$item has no step to send back to (its gate predates gate_from); clear it with the change instead" 2
      [ "$step" != split ] || die "$item is already split into tracker tasks; close its children to keep it whole, then clear the gate" 2
      step_runs "$from" || die "$item has no step to send back to: its ${gate:-gate} gate judges the $from step, which no run does again. Do it by hand, then clear the gate with no answer: gate.sh clear $item"
      pending=next
    elif [ "$mode" = met ]; then :
    elif [ -z "$given" ] && ! step_runs "$step"; then :
    else
      case "$(answer_carrier "$step" "$gate" "$pr")" in
        "$CARRIER_SWEEP"|"$CARRIER_CHILDREN") ;;
        "$CARRIER_COMMENTS") pending=comments ;;
        "$CARRIER_OWNER")
          [ "$step" != done ] || [ -z "$pr" ] || die "no step acts on this answer: $item is done and its PR $pr is $(read_pr_state "$pr" | tr '[:upper:]' '[:lower:]'), so no comments pass would carry it out. Do it by hand, then clear the gate with no answer (gate.sh clear $item). The ${gate:-gate} gate stays."
          hint=""; [ -n "$from" ] && step_runs "$from" && hint=", or send it back to $from: gate.sh clear $item --back \"<what to change>\""
          die "no step acts on this answer: $item is at step ${step:-none} with no PR, so no run would carry it out. Do it by hand, then clear the gate with no answer (gate.sh clear $item)$hint. The ${gate:-gate} gate stays." ;;
        *) pending=next ;;
      esac
    fi
    for h in claude codex; do
      f="$(host_stop_file "$h")"
      [ -f "$f" ] && [ "$(json_get "$(cat "$f")" item)" = "$item" ] && rm -f "$f" && echo "$h starts sessions again"
    done
    # One events.log line per answer, so the console can list what was answered today.
    answered_event() { mkdir -p "$home"; printf '%s\t%s\tanswered\t%s\n' "$(now_iso)" "$item" "$(printf '%s' "$1" | tr '\n' ' ')" >> "$home/events.log"; }
    if [ "$mode" = back ]; then
      # The question and the answer stay in the state, so the from step's brief carries them, and
      # answered_at dates the answer that waits on next (the board's Health).
      sent_at="$(now_iso)"
      step_write "$item" "gate=none" "gate_from=" "step=$from" "attempts=0" "answered=$gate, sent back" "asked=$asked" "answer=$message" \
        "answered_at=$sent_at" "answer_pending=$pending" "last_event=$sent_at gate sent back to $from: $message" >/dev/null
      adapter comment "$item" --body "Gate sent back to $from: $message" >/dev/null
      answered_event "${gate:-gate}, sent back to $from: $message"
      rm -f "$record"
      echo "gate sent back on $item; run next $item to run $from again"; exit 0
    fi
    if [ "$mode" = met ]; then
      # Not the owner's answer: no answered line, nothing pending, and the item keeps its step, so
      # the next pass runs it.
      met_at="$(now_iso)"
      adapter write-state "$item" "gate=none" "gate_from=" "attempts=0" "answered=$gate, condition met" "asked=$asked" "answer=$given" \
        "answer_pending=" "last_event=$met_at gate cleared by health: $given" >/dev/null
      adapter comment "$item" --body "Gate cleared by the health job: $given" >/dev/null
      rm -f "$record"
      if step_runs "$step"; then echo "gate cleared on $item: $given; run next $item to continue"
      else echo "gate cleared on $item: $given; nothing runs on it (step ${step:-none})"; fi
      exit 0
    fi
    # The question and the answer stay in the state, so the next step's brief carries them.
    # answered_at stays too: the comments job counts a clear as new activity on the item's PR.
    cleared_at="$(now_iso)"
    adapter write-state "$item" "gate=none" "gate_from=" "attempts=0" "answered=$answered_as" "asked=$asked" "answer=$message" \
      "answered_at=$cleared_at" "answer_pending=$pending" "last_event=$cleared_at gate cleared: $message" >/dev/null
    adapter comment "$item" --body "Gate cleared: $message" >/dev/null
    answered_event "$answered_line"
    rm -f "$home/gates/$(item_slug "$item").json"
    # The split happened when the plan step ended (advance.sh). Clearing the gate never splits; an
    # owner who closed the children to keep the item whole gets its plan step back.
    if [ "$gate" = decomposition ]; then
      data="$(adapter read "$item" 2>/dev/null)"
      if [ "$(state_get "$data" step)" = split ] && [ "$(json_get "$data" open_children)" = 0 ]; then
        step_write "$item" "step=plan" "answer_pending=next" "last_event=$(now_iso) kept whole: the children are closed, the plan step runs again" >/dev/null
        "$FLOW_PLUGIN/scripts/steward.sh" keep-whole "$item" >/dev/null
        echo "gate cleared on $item; its children are closed, so it is whole again: next $item runs the plan step"; exit 0
      fi
    fi
    case "$pending:$step" in
      comments:*) echo "gate cleared on $item; it is done, so the comments job carries the answer out on its next pass on $pr (now: jobs/comments.sh <host> $item)" ;;
      next:*|*:split) echo "gate cleared on $item; run next $item to continue" ;;
      *) echo "gate cleared on $item; nothing runs on it (step ${step:-none})" ;;
    esac ;;
  list)
    case "$#:${2:-}" in
      1:) ;;
      2:--json) gates_json; exit ;;
      *) die "usage: gate.sh list [--json]" 2 ;;
    esac
    for f in "$home"/gates/*.json; do
      [ -f "$f" ] || continue
      c="$(cat "$f")"
      printf '%s\t%s\t%s\t%s\n' "$(json_get "$c" time)" "$(json_get "$c" item)" "$(json_get "$c" gate)" "$(json_get "$c" message | head -1)"
    done
    # A stopped host is a line too: the host for the item, stopped for the gate.
    for f in "$home"/log/claude.stopped "$home"/log/codex.stopped; do
      [ -f "$f" ] || continue
      c="$(cat "$f")"
      printf '%s\t%s\tstopped\t%s: %s\n' "$(json_get "$c" at)" "$(json_get "$c" host)" "$(json_get "$c" cause)" "$(json_get "$c" said)"
    done ;;
  *) sed -n '2,47p' "$0"; exit 2 ;;
esac
