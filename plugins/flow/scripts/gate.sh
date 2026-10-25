#!/bin/sh
# Human gates.
#   gate.sh raise <item> <gate> <message>   record the gate in the tracker, notify, stop the run
#   gate.sh clear <item> [<message>]        the owner's answer: gate back to none, run can resume;
#                                           on the decomposition gate of a split task whose
#                                           children are all closed, the plan step runs again
#   gate.sh list [--json]                   pending gates; --json prints one array, oldest first,
#                                           with the claimed worktree, the age and the questions
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

case "${1:-}" in
  raise)
    [ $# -ge 4 ] || die "usage: gate.sh raise <item> <gate> <message>" 2
    item="$2"; gate="$3"; message="$4"
    json_get "$(cat "$FLOW_PLUGIN/profiles.json")" "gates.$gate" >/dev/null 2>&1 || true
    adapter write-state "$item" "gate=$gate" "last_event=$(now_iso) gate $gate" >/dev/null
    adapter comment "$item" --body "**Gate: $gate**

$message" >/dev/null
    rm -f "$home/runs/$(item_slug "$item").json"
    [ "$gate" = "escalation" ] && "$FLOW_PLUGIN/scripts/lesson.sh" escalation "$item" "$message" >/dev/null
    "$FLOW_PLUGIN/scripts/notify.sh" "$gate" "$item" "$message" ;;
  clear)
    [ $# -ge 2 ] || die "usage: gate.sh clear <item> [<message>]" 2
    item="$2"; message="${3:-cleared}"
    record="$home/gates/$(item_slug "$item").json"; asked=""; gate=""
    [ -f "$record" ] && { asked="$(json_get "$(cat "$record")" message)"; gate="$(json_get "$(cat "$record")" gate)"; }
    [ -n "$gate" ] || { gate="$(state_get "$(adapter read "$item" 2>/dev/null)" gate)"; [ "$gate" != none ] || gate=""; }
    # The question and the answer stay in the state, so the next step's brief carries them.
    adapter write-state "$item" "gate=none" "attempts=0" "answered=$gate" "asked=$asked" "answer=$message" \
      "last_event=$(now_iso) gate cleared: $message" >/dev/null
    adapter comment "$item" --body "Gate cleared: $message" >/dev/null
    rm -f "$home/gates/$(item_slug "$item").json"
    # The split happened when the plan step ended (advance.sh). Clearing the gate never splits; an
    # owner who closed the children to keep the item whole gets its plan step back.
    if [ "$gate" = decomposition ]; then
      data="$(adapter read "$item" 2>/dev/null)"
      if [ "$(state_get "$data" step)" = split ] && [ "$(json_get "$data" open_children)" = 0 ]; then
        adapter write-state "$item" "step=plan" "last_event=$(now_iso) kept whole: the children are closed, the plan step runs again" >/dev/null
        "$FLOW_PLUGIN/scripts/steward.sh" keep-whole "$item" >/dev/null
        echo "gate cleared on $item; its children are closed, so it is whole again: next $item runs the plan step"; exit 0
      fi
    fi
    echo "gate cleared on $item; run next $item to continue" ;;
  list)
    case "$#:${2:-}" in
      1:) ;;
      2:--json) gates_json; exit ;;
      *) die "usage: gate.sh list [--json]" 2 ;;
    esac
    [ -d "$home/gates" ] || exit 0
    for f in "$home"/gates/*.json; do
      [ -f "$f" ] || continue
      c="$(cat "$f")"
      printf '%s\t%s\t%s\t%s\n' "$(json_get "$c" time)" "$(json_get "$c" item)" "$(json_get "$c" gate)" "$(json_get "$c" message | head -1)"
    done ;;
  *) sed -n '2,11p' "$0"; exit 2 ;;
esac
