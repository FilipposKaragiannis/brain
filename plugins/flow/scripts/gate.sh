#!/bin/sh
# Human gates.
#   gate.sh raise <item> <gate> <message> [<from step>]
#                                           record the gate in the tracker, notify, stop the run;
#                                           <from step> is the step whose work the gate judges
#                                           (default: the item's step now), where --back returns
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
#   gate.sh clear <claude|codex>            start sessions on a host a spend limit, an auth
#                                           error or an unknown model stopped outside any item's run
#   gate.sh list [--json]                   pending gates; --json prints one array, oldest first,
#                                           with the claimed worktree, the age and the questions
#   gate.sh drop <item> <why>               the item closed under the gate (steward.sh sweep): the
#                                           gate, its record and its gate: label go, no answer
#                                           recorded; an ambiguity or escalation question nobody
#                                           answered is posted on the item and printed, marked
#                                           unanswered, so the owner can file a follow-up
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

# gate_drop <item> <why>: the item closed under its gate. The gate, its record and its gate:
# label go and no answer is recorded. An ambiguity or escalation question goes to the item and to
# stdout, marked unanswered (gate_unanswered). An item with no gate is left as it is.
gate_drop() {
  item="$1"; why="$2"; record="$home/gates/$(item_slug "$item").json"
  gate_record="$(cat "$record" 2>/dev/null)"
  gate="$(json_get "$gate_record" gate)"; asked="$(json_get "$gate_record" message)"
  if [ -z "$gate" ]; then
    item_data="$(adapter read "$item" 2>/dev/null)"
    gate="$(state_get "$item_data" gate)"; [ "$gate" != none ] || gate=""
  fi
  [ -n "$gate" ] || return 0
  adapter write-state "$item" "gate=none" "gate_from=" "last_event=$(now_iso) gate $gate dropped: $why" >/dev/null \
    || die "cannot drop the $gate gate of $item; it stays"
  rm -f "$record"
  case "$gate" in
    ambiguity|escalation) gate_unanswered "$item" "$gate" "$why" "$asked" ;;
    *)
      adapter comment "$item" --body "Gate dropped: the $gate gate closed with the item ($why)." >/dev/null || echo "flow: could not comment on $item" >&2
      echo "$item: dropped the $gate gate ($why)" ;;
  esac
}

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
    [ $# -ge 4 ] || die "usage: gate.sh raise <item> <gate> <message> [<from step>]" 2
    item="$2"; gate="$3"; message="$4"; from="${5:-}"
    json_get "$(cat "$FLOW_PLUGIN/profiles.json")" "gates.$gate" >/dev/null 2>&1 || true
    [ -n "$from" ] || from="$(state_get "$(adapter read "$item" 2>/dev/null)" step)"
    adapter write-state "$item" "gate=$gate" "gate_from=$from" "last_event=$(now_iso) gate $gate" >/dev/null
    adapter comment "$item" --body "**Gate: $gate**

$message" >/dev/null
    rm -f "$home/runs/$(item_slug "$item").json"
    [ "$gate" = "escalation" ] && "$FLOW_PLUGIN/scripts/lesson.sh" escalation "$item" "$message" >/dev/null
    "$FLOW_PLUGIN/scripts/notify.sh" "$gate" "$item" "$message" ;;
  clear)
    [ $# -ge 2 ] || die "usage: gate.sh clear <item> [<message>] | gate.sh clear <item> --back <message>" 2
    item="$2"; back=0
    [ "${3:-}" = --back ] && { back=1; shift; }
    message="${3:-cleared}"; given="${3:-}"
    [ "$back" -eq 0 ] || [ -n "$given" ] || die "gate.sh clear --back needs a message: what to change" 2
    # A host stopped on a spend limit, an auth error or an unknown model (lib/host.sh) starts sessions again when
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
    # runs <step>: next.sh runs it: a profile step, or the first one of an item not started.
    # json_get prints nothing for a missing key, and exits 0 either way.
    runs() { [ -z "$1" ] || [ -n "$(json_get "$(cat "$FLOW_PLUGIN/profiles.json")" "steps.$1")" ]; }
    # Who carries out the answer, kept in answer_pending until a run takes it (the board shows it):
    # next, when the item's step is one it runs; the comments job, at done with a PR (a gate a
    # comments pass raised). The merge gate's answer is the merge itself; a clear with no answer,
    # or one that lets a split stand, carries nothing out. Any other answer no step acts on: the
    # clear fails and the gate stays, so an answer is never dropped in silence.
    pending=""
    if [ "$back" -eq 1 ]; then
      [ -n "$from" ] || die "$item has no step to send back to (its gate predates gate_from); clear it with the change instead" 2
      [ "$step" != split ] || die "$item is already split into tracker tasks; close its children to keep it whole, then clear the gate" 2
      runs "$from" || die "$item has no step to send back to: its ${gate:-gate} gate judges the $from step, which no run does again. Do it by hand, then clear the gate with no answer: gate.sh clear $item"
      pending=next
    elif [ "$gate" = merge ]; then :
    elif runs "$step"; then pending=next
    elif [ -z "$given" ]; then :
    elif [ "$step" = split ] && [ "$gate" = decomposition ]; then :
    elif [ "$step" = done ] && [ -n "$pr" ]; then
      # The comments job passes only on an open PR. One it cannot read counts as open: the job
      # logs why it skips it, and the board shows the answer waiting.
      pr_state="$("$FLOW_PLUGIN/scripts/comments.sh" state "$pr" 2>/dev/null)" && pr_state="$(json_get "$pr_state" state 2>/dev/null)" || pr_state=""
      case "${pr_state:-OPEN}" in
        OPEN) pending=comments ;;
        *) die "no step acts on this answer: $item is done and its PR $pr is $(printf '%s' "$pr_state" | tr '[:upper:]' '[:lower:]'), so no comments pass would carry it out. Do it by hand, then clear the gate with no answer (gate.sh clear $item). The ${gate:-gate} gate stays." ;;
      esac
    else
      hint=""; [ -n "$from" ] && runs "$from" && hint=", or send it back to $from: gate.sh clear $item --back \"<what to change>\""
      die "no step acts on this answer: $item is at step ${step:-none} with no PR, so no run would carry it out. Do it by hand, then clear the gate with no answer (gate.sh clear $item)$hint. The ${gate:-gate} gate stays."
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
  drop)
    [ $# -eq 3 ] || die "usage: gate.sh drop <item> <why>" 2
    gate_drop "$2" "$3" ;;
  *) sed -n '2,29p' "$0"; exit 2 ;;
esac
