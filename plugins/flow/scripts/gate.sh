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
. "$FLOW_PLUGIN/lib/host.sh"
. "$FLOW_PLUGIN/lib/gate.sh"
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
    given="${3:-}"
    case "$mode:$option_number:$given" in
      back::--option|option:--back:*|option:*:--back) die "gate.sh clear takes --option or --back, not both: a pick answers the gate, a send-back redoes its step" 2 ;;
      back::) die "gate.sh clear --back needs a message: what to change" 2 ;;
      met::) die "gate.sh clear --met needs a note: the condition that no longer holds" 2 ;;
    esac
    # A host stopped on a spend limit or an auth error (lib/host.sh) starts sessions again when
    # the gate that names it clears, or when the owner clears the host by name.
    case "$item" in claude|codex)
      [ -f "$(host_stop_file "$item")" ] || { echo "$item is not stopped"; exit 0; }
      rm -f "$(host_stop_file "$item")"; echo "$item starts sessions again"; exit 0 ;;
    esac
    lock_gate_clears "$item"
    record="$home/gates/$(item_slug "$item").json"; asked=""; gate=""; record_json=""
    [ -f "$record" ] && { record_json="$(cat "$record")"; asked="$(json_get "$record_json" message)"; gate="$(json_get "$record_json" gate)"; }
    case "$mode" in
      met)
        [ -n "$record_json" ] || { echo "gate already cleared on $item"; exit 0; }
        [ -n "$(json_get "$record_json" condition)" ] || die "the ${gate:-gate} gate on $item waits on no condition, so only the owner's answer clears it: gate.sh clear $item \"<answer>\"" 2 ;;
      option) option_answer="$(picked_option_answer "$option_number" "$given")" || exit $? ;;
    esac
    data="$(adapter read "$item" 2>/dev/null)"
    [ -n "$gate" ] || { gate="$(state_get "$data" gate)"; [ "$gate" != none ] || gate=""; }
    step="$(state_get "$data" step)"; from="$(state_get "$data" gate_from)"; pr="$(state_get "$data" pr)"
    case "$mode" in
      back) clear_back "$given" ;;
      met) clear_met "$given" ;;
      option) clear_option "$option_number" "$option_answer" ;;
      *) clear_answer "$given" ;;
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
