#!/bin/sh
# board.sh [--json] [--graph <epic-id>|priorities [--mermaid]]: every tracker read, every claim. The pool
# with item, step and last event; open items with their state and open blockers (--json:
# open_blockers on every item, the tracker's own list, else those of blocked_by not read as closed,
# as next.sh judges them; a claimed item waits on them at every step), and in the gate column
# the owner's answer to a cleared gate while it waits on a run (answer_pending; in Health too once
# it waits past the gate reminder); pending gates; overlapping claims; the spend per item, from
# the step sessions in log/runs.jsonl; each tracker whose list failed, with why (--json:
# tracker_errors, [{"tracker", "code", "message"}]); the status of each holder an open item is
# held behind that the list leaves out (--json: holders, [{"id", "status"}], status open, closed or
# unknown). --graph prints a graph model built from every adapter's open items (scripts/_graph.py):
# the dependency waves of one epic's children, or every open item by priority. --mermaid prints it
# as a Mermaid flowchart instead of JSON.
. "$(dirname "$0")/../lib/flow.sh"
home="$(flow_home)"
as_json=0; graph=""; mermaid=""
while [ $# -gt 0 ]; do
  case "$1" in
    --json) as_json=1; shift ;;
    --graph) [ $# -ge 2 ] || die "--graph takes an epic id or priorities" 2; graph="$2"; shift 2 ;;
    --mermaid) mermaid="--mermaid"; shift ;;
    *) die "unknown option $1" 2 ;;
  esac
done
[ -z "$mermaid" ] || [ -n "$graph" ] || die "--mermaid goes with --graph" 2
ready_rules
trackers="$(adapters_configured)" || exit 2
merge_lists() { python3 -I -c '
import json, sys
out = []
for line in sys.stdin:
    if line.strip(): out.extend(json.loads(line))
print(json.dumps(out))'; }
# A graph from a list that failed or was cut short is wrong, so a graph lets the adapters' errors
# through and stops when one fails. FLOW_LIST_WHOLE makes a list cut at its limit fail. The board
# shows what it can.
if [ -n "$graph" ]; then
  lists="$(for a in $trackers; do FLOW_LIST_WHOLE=1 adapter list "$a" || exit 1; done)" || die "an adapter could not list its items, so no graph" 1
  case "$graph" in priorities) set -- priorities ;; *) set -- epic "$graph" ;; esac
  printf '%s\n' "$lists" | merge_lists | python3 -I "$FLOW_PLUGIN/scripts/_graph.py" "$@" $mermaid
  exit
fi
procs="$(mktemp)"; failed="$(mktemp)"; said="$(mktemp)"; listed="$(mktemp)"; trap 'rm -f "$procs" "$failed" "$said" "$listed"' EXIT
# A tracker whose list fails is named with its exit code and its last stderr line (a missing token,
# a refused config key), so the board says why its items are missing instead of showing fewer.
items="$(for a in $trackers; do
  adapter list "$a" 2>"$said"; code=$?
  [ "$code" -eq 0 ] || { json_obj "tracker=$a" "code:=$code" "message=$(grep . "$said" | tail -n 1)"; echo; } >> "$failed"
done | merge_lists)"
tracker_errors="$(sed 's/.*/[&]/' "$failed" | merge_lists)"
# Each run record says whether a process still holds it: "running on shell" is only true then.
grace="$(python3 -I "$FLOW_PLUGIN/scripts/_health.py" seconds jobs.health.grace "$(cfg_or jobs.health.grace 10m)")" || exit 2
reminder="$(python3 -I "$FLOW_PLUGIN/scripts/_health.py" seconds jobs.health.gate_reminder "$(cfg_or jobs.health.gate_reminder 24h)")" || exit 2
python3 -I "$FLOW_PLUGIN/scripts/_health.py" procs > "$procs"
runs="$(python3 -I "$FLOW_PLUGIN/scripts/_health.py" runs "$home/runs" "$procs" "$grace")"
# A record that does not parse (one written before 1.20.2 with a value such as 007) is skipped.
gates="$(for f in "$home"/gates/*.json; do [ -f "$f" ] && cat "$f" && echo; done | python3 -I -c '
import json, sys
out = []
for l in sys.stdin:
    try:
        out.append(json.loads(l))
    except ValueError:
        pass
print(json.dumps(out))')"
pool="$("$FLOW_PLUGIN/scripts/steward.sh" pool 2>/dev/null | tail -n +2)"
# The list has open items only, so a holder (state.held_by) it leaves out is read, once each:
# open, closed, or unknown when it cannot be read. A closed one holds nothing (filter-ready.sh).
holders="$(printf '%s\n' "$items" > "$listed" && python3 -I "$FLOW_PLUGIN/scripts/_health.py" holders "$listed" | while read -r h; do
  [ -n "$h" ] || continue
  hs="$(json_get "$(adapter read "$h" 2>/dev/null)" status 2>/dev/null)"
  json_obj "id=$h" "status=${hs:-unknown}"; echo
done | python3 -I -c '
import json, sys
print(json.dumps([json.loads(l) for l in sys.stdin if l.strip()]))')"
# A blocker the lists leave out (closed, missing, or another tracker's) of an item whose tracker
# keeps no open_blockers list is read, once each, as next.sh reads it (lib/blockers.sh): open,
# closed, or unknown when it cannot be read. Only a closed one holds nothing.
blockers="$(python3 -I -c '
import json, sys
items = json.load(open(sys.argv[1]))
listed, seen = {item["id"] for item in items}, set()
for item in items:
    for blocker in [] if "open_blockers" in item else item.get("blocked_by", []):
        if blocker not in listed and blocker not in seen:
            seen.add(blocker)
            print(blocker)' "$listed" | while read -r blocker; do
  blocker_status="$(json_get "$(adapter read "$blocker" </dev/null 2>/dev/null)" status 2>/dev/null)"
  json_obj "id=$blocker" "status=${blocker_status:-unknown}"; echo
done | python3 -I -c '
import json, sys
print(json.dumps([json.loads(l) for l in sys.stdin if l.strip()]))')"
printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$items" "$runs" "$gates" "$tracker_errors" "$holders" "$blockers" | python3 -I "$FLOW_PLUGIN/scripts/_board.py" "$as_json" "$pool" "$reminder" "$home/log"
