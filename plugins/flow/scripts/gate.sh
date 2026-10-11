#!/bin/sh
# Human gates.
#   gate.sh raise <item> <gate> <message>   record the gate in the tracker, notify, stop the run
#   gate.sh clear <item> [<message>]        the owner's answer: gate back to none, run can resume
#   gate.sh list                            pending gates
# Gates: interview, plan-approval, decomposition, feel-test, merge, escalation, ambiguity.
. "$(dirname "$0")/../lib/flow.sh"
home="$(flow_home)"
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
    adapter write-state "$item" "gate=none" "attempts=0" "last_event=$(now_iso) gate cleared: $message" >/dev/null
    adapter comment "$item" --body "Gate cleared: $message" >/dev/null
    rm -f "$home/gates/$(item_slug "$item").json"
    echo "gate cleared on $item; run next $item to continue" ;;
  list)
    [ -d "$home/gates" ] || exit 0
    for f in "$home"/gates/*.json; do
      [ -f "$f" ] || continue
      c="$(cat "$f")"
      printf '%s\t%s\t%s\t%s\n' "$(json_get "$c" time)" "$(json_get "$c" item)" "$(json_get "$c" gate)" "$(json_get "$c" message | head -1)"
    done ;;
  *) sed -n '2,6p' "$0"; exit 2 ;;
esac
