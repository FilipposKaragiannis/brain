#!/bin/sh
# Human gates.
#   gate.sh raise <item> <gate> <message> [<from step>] [--options <json>] [--condition <text>]
#                 [--raised-by <who>] [-- <key=value>...]
#                                           record the gate, notify, stop the run;
#                                           notify.sh writes the gate's record into the flow
#                                           record (its view: scripts/_state_views.py);
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
#                                           carry under the message. Trailing state pairs after a
#                                           `--` (step=implement ...) go into the one record write
#                                           that records the gate, so no reader sees the one
#                                           without the other. A write the tracker refuses raises
#                                           nothing, exit 1, unless tracker_state is labels and the
#                                           tracker shows the gate after it (labels that landed
#                                           before the state comment or property failed): then
#                                           the flow record alone takes the whole write and the
#                                           gate stands, with a warning that the tracker lags; a
#                                           record that cannot take it raises nothing, exit 1.
#                                           A comment or notification that fails after the write
#                                           is said on stderr and the gate stands. Then the
#                                           tracker's status follows (lib/push.sh tracker_push):
#                                           in-review for merge, needs-you for the others
#   gate.sh clear <item> [<message>]        the owner's answer: gate back to none, run can resume;
#                                           on the decomposition gate of a split task whose
#                                           children are all closed, the plan step runs again;
#                                           on the decomposition gate of an epic, the epic gets
#                                           its epic branch, which its children start from;
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
#                                           of range, or with --back. On a gate that waits on
#                                           blocked_by:<blocker>, the pick waives that blocker:
#                                           next.sh and the ready filter no longer hold the item
#                                           behind it (lib/blockers.sh)
#   gate.sh clear <item> --met <condition>  the condition the health job read no longer holds:
#                                           nothing waits on a run, the item keeps its step; exit 2
#                                           when the gate has no condition, exit 1 when it waits on
#                                           another one; "already cleared", exit 0, when its record
#                                           is gone
#                                           Then the tracker's status follows (lib/push.sh
#                                           tracker_push), after the lock, but for a merge gate
#                                           cleared at done
#                                           Each clear of an item waits for another one to finish
#                                           (exit 75 after 10s) and reads the record after it
#   gate.sh clear <claude|codex>            start sessions on a host a spend limit, an auth
#                                           error or an unknown model stopped outside any item's run
#   gate.sh list [--json]                   pending gates; --json prints one array, oldest first,
#                                           with the claimed worktree, the age, the questions, the
#                                           options, who raised it, who answers it, its condition
#                                           and its footer
#   gate.sh drop <item> <why>               the item closed under the gate (steward.sh sweep): the
#                                           gate, its record and its gate: label go, no answer
#                                           recorded; an ambiguity or escalation question nobody
#                                           answered is posted on the item and printed, marked
#                                           unanswered, so the owner can file a follow-up
# Gates: interview, plan-approval, decomposition, feel-test, merge, escalation, ambiguity.
# FLOW_NOW (an ISO time, 2026-10-25T09:00:00Z) stands in for the clock in the age. It exists for
# tests, like FLOW_HOME.
. "$(dirname "$0")/../lib/flow.sh"
. "$FLOW_PLUGIN/lib/host.sh"
. "$FLOW_PLUGIN/lib/blockers.sh"
. "$FLOW_PLUGIN/lib/base.sh"
. "$FLOW_PLUGIN/lib/gate.sh"
home="$(flow_home)"

# gates_json: each gate row (record_list gates) with its claimed worktree (steward.sh find) or
# null, through scripts/_gates.py, which adds the age and the parsed questions. record_list leaves
# out a record that does not parse and names it on stderr, so one bad record never hides the
# other gates.
gates_json() {
  record_list gates | while IFS= read -r record; do
    item="$(json_get "$record" item)"; worktree=""
    [ -n "$item" ] && worktree="$("$FLOW_PLUGIN/scripts/steward.sh" find "$item" </dev/null)"
    if [ -n "$worktree" ]; then json_set "$record" worktree "$(json_string "$worktree")"; else json_set "$record" worktree null; fi
  done | cached_python3 -I "$FLOW_PLUGIN/scripts/_gates.py" "${FLOW_NOW:-$(now_iso)}"
}

refused_gate_name_limit=60
RAISE_USAGE="usage: gate.sh raise <item> <gate> <message> [<from step>] [--options <json>] [--condition <text>] [--raised-by <who>] [-- <key=value>...]"
OPTION_AND_BACK="gate.sh clear takes --option or --back, not both: a pick answers the gate, a send-back redoes its step"
CLEAR_USAGE="usage: gate.sh clear <item> [<message>] | gate.sh clear <item> --back <message> | gate.sh clear <item> --option <n> [<note>] | gate.sh clear <item> --met <condition>"

# parse_raise_flags <flag> <value> ... [-- ...]: sets options_given, condition_given and raised_by_given
# from raise's --options, --condition and --raised-by up to a `--`; dies, exit 2, on anything else.
parse_raise_flags() {
  options_given=""; condition_given=""; raised_by_given=""
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    [ $# -ge 2 ] || die "$RAISE_USAGE" 2
    case "$1" in
      --options) options_given="$2" ;;
      --condition) condition_given="$2" ;;
      --raised-by) raised_by_given="$2" ;;
      *) die "$RAISE_USAGE" 2 ;;
    esac
    shift 2
  done
}

# gate_drop <item> <why>: the item closed under its gate. The gate, its record and its gate:
# label go and no answer is recorded. An ambiguity or escalation question goes to the item and to
# stdout, marked unanswered (gate_unanswered). An item with no gate is left as it is. It holds the
# item's clear lock (lock_gate_clears), so a drop and a clear never take one gate twice.
gate_drop() {
  item="$1"; why="$2"; lock_gate_clears "$item"
  gate_row="$(gate_record "$item" 2>/dev/null)"
  gate="$(json_get "$gate_row" gate)"; asked="$(json_get "$gate_row" message)"
  if [ -z "$gate" ]; then
    item_data="$(item_read "$item" 2>/dev/null)"
    gate="$(state_get "$item_data" gate)"; [ "$gate" != none ] || gate=""
  fi
  [ -n "$gate" ] || return 0
  record_set "$item" "gate=none" "gate_from=" "last_event=$(now_iso) gate $gate dropped: $why" >/dev/null \
    || die "cannot drop the $gate gate of $item; it stays"
  case "$gate" in
    ambiguity|escalation) gate_unanswered "$item" "$gate" "$why" "$asked" ;;
    *)
      adapter comment "$item" --body "Gate dropped: the $gate gate closed with the item ($why)." >/dev/null || echo "flow: could not comment on $item" >&2
      echo "$item: dropped the $gate gate ($why)" ;;
  esac
}

# merge_cleared_at_done: the merge gate went and the item stays done, as when the sweep clears it on
# a merged PR: its card is in review already and the item is closed or closing, so no push moves it.
merge_cleared_at_done() { [ "$gate" = merge ] && [ "$(record_get "$item" step)" = "done" ]; }

# gate_unanswered <item> <gate> <why> <question>: the question nobody answered, quoted on the item
# (headed Unanswered, not Gate, so no answers pass reads it as a gate) and on stdout, for a
# follow-up. A question with no record points at the gate's own comment.
gate_unanswered() {
  quoted="$(printf '%s\n' "${4:-(the question is in the gate comment above)}" | sed 's/^/> /')"
  adapter comment "$1" --body "**Unanswered: the $2 gate closed with the item** ($3). Nobody answered it; file a follow-up if the question still stands:

$quoted" >/dev/null || echo "flow: could not post the unanswered $2 question on $1" >&2
  echo "$1: dropped the $2 gate unanswered ($3); file a follow-up if the question still stands:"
  printf '%s\n' "$quoted" | sed 's/^/  /'
}

case "${1:-}" in
  raise)
    [ $# -ge 4 ] || die "$RAISE_USAGE" 2
    item="$2"; gate="$3"; message="$4"; from=""; shift 4
    case "${1:-}" in --*) ;; *) [ $# -eq 0 ] || { from="$1"; shift; } ;; esac
    parse_raise_flags "$@"
    while [ $# -gt 0 ] && [ "$1" != -- ]; do shift 2; done
    [ $# -eq 0 ] || shift
    gate_known "$gate" || die "unknown gate '$(printf '%s' "$gate" | tr -cd '[:print:]' | head -c "$refused_gate_name_limit")': nothing raised; the gates are $(cached_python3 -I -c 'import json, sys; print(", ".join(json.load(open(sys.argv[1]))["gates"]))' "$FLOW_PLUGIN/profiles.json")" 2
    data="$(item_read "$item" 2>/dev/null)"; step="$(state_get "$data" step)"
    [ -n "$from" ] || from="$step"
    for state_pair in "$@"; do case "$state_pair" in step=*) step="${state_pair#step=}" ;; esac; done
    options="$(raise_options "$item" "$options_given")"
    condition="$(raise_condition "$item" "$condition_given")"
    raised_by="$(raised_by_default "$raised_by_given" "$item" "$step")"
    carrier="$(carrier_row "$(carrier_kind "$step" "$gate" "$(state_get "$data" pr)")" "$item" "$step" "$(option_hint "$options")")"
    answered_by="$(carrier_field "$carrier" "$FIELD_ANSWERED_BY")"
    footer="$(gate_footer "$condition" "$(carrier_field "$carrier" "$FIELD_HOW_TO_CLEAR")")"
    condition_field="condition:=null"; [ -z "$condition" ] || condition_field="condition=$condition"
    if ! record_set "$item" "gate=$gate" "gate_from=$from" "last_event=$(now_iso) gate $gate" "$@" >/dev/null; then
      [ "$(tracker_state)" = labels ] && [ "$(json_get "$( (adapter read "$item") </dev/null 2>/dev/null)" state.gate)" = "$gate" ] \
        || die "cannot record the $gate gate on $item, and its tracker does not show it: nothing raised, its run stays"
      record_set_unmirrored "$item" "gate=$gate" "gate_from=$from" "last_event=$(now_iso) gate $gate" "$@" >/dev/null \
        || die "its tracker shows the $gate gate on $item, but its flow record could not take it: nothing raised, its run stays"
      echo "flow: the tracker write of the $gate gate on $item failed part way; the gate stands in its flow record, and its tracker's state may lag until the next write" >&2
    fi
    adapter comment "$item" --body "**Gate: $gate**

$message

$footer" >/dev/null || echo "flow: the $gate gate on $item is recorded, but its comment could not be posted" >&2
    record_set "$item" "run:=null"
    [ "$gate" = "escalation" ] && "$FLOW_PLUGIN/scripts/lesson.sh" escalation "$item" "$message" >/dev/null
    "$FLOW_PLUGIN/scripts/notify.sh" "$gate" "$item" "$message" "options:=$options" "raised_by=$raised_by" \
      "answered_by=$answered_by" "$condition_field" "footer=$footer" \
      || echo "flow: the $gate gate on $item is recorded, but notify.sh failed" >&2
    tracker_push "$item" ;;
  clear)
    [ $# -ge 2 ] || die "$CLEAR_USAGE" 2
    item="$2"; mode=answer; option_number=""
    case "${3:-}" in
      --back) [ "${4:-}" != --option ] || die "$OPTION_AND_BACK" 2; mode=back; shift ;;
      --option) [ $# -ge 4 ] || die "$CLEAR_USAGE" 2
        [ "$4" != --back ] && [ "${5:-}" != --back ] || die "$OPTION_AND_BACK" 2
        mode=option; option_number="$4"; shift 2 ;;
      --met) mode=met; shift ;;
    esac
    given="${3:-}"
    case "$mode:$given" in
      back:) die "gate.sh clear --back needs a message: what to change" 2 ;;
      met:) die "gate.sh clear --met needs the condition that no longer holds" 2 ;;
    esac
    # A host stopped on a spend limit, an auth error or an unknown model (lib/host.sh) starts sessions again when
    # the gate that names it clears, or when the owner clears the host by name.
    case "$item" in claude|codex)
      [ -f "$(host_stop_file "$item")" ] || { echo "$item is not stopped"; exit 0; }
      rm -f "$(host_stop_file "$item")"; echo "$item starts sessions again"; exit 0 ;;
    esac
    lock_gate_clears "$item"
    record_json="$(gate_record "$item")" || exit
    asked="$(json_get "$record_json" message)"; gate="$(json_get "$record_json" gate)"
    case "$mode" in
      met)
        [ -n "$record_json" ] || { echo "gate already cleared on $item"; exit 0; }
        recorded_condition="$(json_get "$record_json" condition)"
        [ -n "$recorded_condition" ] || die "the ${gate:-gate} gate on $item waits on no condition, so only the owner's answer clears it: gate.sh clear $item \"<answer>\"" 2
        [ "$recorded_condition" = "$given" ] || die "the ${gate:-gate} gate on $item waits on $recorded_condition, not $given, so it stays; the health job reads it on its next pass" ;;
      option) option_answer="$(picked_option_answer "$option_number" "$given")" || exit $? ;;
    esac
    data="$(item_read "$item" 2>/dev/null)"
    [ -n "$gate" ] || { gate="$(state_get "$data" gate)"; [ "$gate" != none ] || gate=""; }
    step="$(state_get "$data" step)"; from="$(state_get "$data" gate_from)"; pr="$(state_get "$data" pr)"
    case "$mode" in
      back) clear_back "$given" ;;
      met) clear_met "$given" ;;
      option) clear_option "$option_number" "$option_answer" ;;
      *) clear_answer "$given" ;;
    esac
    flow_unlock
    merge_cleared_at_done || tracker_push "$item" ;;
  list)
    case "$#:${2:-}" in
      1:) ;;
      2:--json) gates_json; exit ;;
      *) die "usage: gate.sh list [--json]" 2 ;;
    esac
    record_list gates | while IFS= read -r c; do
      printf '%s\t%s\t%s\t%s\n' "$(json_get "$c" time)" "$(json_get "$c" item)" "$(json_get "$c" gate)" "$(json_get "$c" message | head -1)"
    done
    # A stopped host is a line too: the host for the item, stopped for the gate.
    for f in "$home"/log/claude.stopped "$home"/log/codex.stopped; do
      [ -f "$f" ] || continue
      c="$(cat "$f")"
      printf '%s\t%s\tstopped\t%s: %s\n' "$(json_get "$c" at)" "$(json_get "$c" host)" "$(json_get "$c" cause)" "$(json_get "$c" said)"
    done ;;
  drop)
    [ $# -eq 3 ] || die "usage: gate.sh drop <item> <why>" 2
    gate_drop "$2" "$3" ;;
  *) awk '/^#!/ { next } /^#/ { print; next } { exit }' "$0"; exit 2 ;;
esac
