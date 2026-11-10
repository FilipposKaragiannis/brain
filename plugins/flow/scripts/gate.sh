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
    [ $# -ge 2 ] || die "usage: gate.sh clear <item> [<message>] | gate.sh clear <item> --back <message>" 2
    item="$2"; back=0
    [ "${3:-}" = --back ] && { back=1; shift; }
    message="${3:-cleared}"; given="${3:-}"
    [ "$back" -eq 0 ] || [ -n "$given" ] || die "gate.sh clear --back needs a message: what to change" 2
    # A host stopped on a spend limit or an auth error (lib/host.sh) starts sessions again when
    # the gate that names it clears, or when the owner clears the host by name.
    . "$FLOW_PLUGIN/lib/host.sh"
    case "$item" in claude|codex)
      [ -f "$(host_stop_file "$item")" ] || { echo "$item is not stopped"; exit 0; }
      rm -f "$(host_stop_file "$item")"; echo "$item starts sessions again"; exit 0 ;;
    esac
    record="$home/gates/$(item_slug "$item").json"; asked=""; gate=""
    [ -f "$record" ] && { asked="$(json_get "$(cat "$record")" message)"; gate="$(json_get "$(cat "$record")" gate)"; }
    data="$(adapter read "$item" 2>/dev/null)"
    [ -n "$gate" ] || { gate="$(state_get "$data" gate)"; [ "$gate" != none ] || gate=""; }
    step="$(state_get "$data" step)"; from="$(state_get "$data" gate_from)"; pr="$(state_get "$data" pr)"
    # Who carries out the answer (answer_carrier), kept in answer_pending until a run takes it (the
    # board shows it): next, when the item's step is one it runs; the comments job, at done with an
    # open PR (a gate a comments pass raised). The merge gate's answer is the merge itself; a clear
    # with no answer, or one that lets a split stand, carries nothing out. Any other answer no step
    # acts on: the clear fails and the gate stays, so an answer is never dropped in silence.
    pending=""
    if [ "$back" -eq 1 ]; then
      [ -n "$from" ] || die "$item has no step to send back to (its gate predates gate_from); clear it with the change instead" 2
      [ "$step" != split ] || die "$item is already split into tracker tasks; close its children to keep it whole, then clear the gate" 2
      step_runs "$from" || die "$item has no step to send back to: its ${gate:-gate} gate judges the $from step, which no run does again. Do it by hand, then clear the gate with no answer: gate.sh clear $item"
      pending=next
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
    if [ "$back" -eq 1 ]; then
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
    # The question and the answer stay in the state, so the next step's brief carries them.
    # answered_at stays too: the comments job counts a clear as new activity on the item's PR.
    cleared_at="$(now_iso)"
    adapter write-state "$item" "gate=none" "gate_from=" "attempts=0" "answered=$gate" "asked=$asked" "answer=$message" \
      "answered_at=$cleared_at" "answer_pending=$pending" "last_event=$cleared_at gate cleared: $message" >/dev/null
    adapter comment "$item" --body "Gate cleared: $message" >/dev/null
    answered_event "${gate:-gate}: $message"
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
  *) sed -n '2,36p' "$0"; exit 2 ;;
esac
