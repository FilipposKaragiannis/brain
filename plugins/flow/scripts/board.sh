#!/bin/sh
# board.sh [--json] [--graph <epic-id>|priorities [--mermaid]]: every adapter, every claim. The pool
# with item, step and last event; open items with their state and blockers; pending gates;
# overlapping claims. --graph prints a graph model built from every adapter's open items
# (scripts/_graph.py): the dependency waves of one epic's children, or every open item by
# priority. --mermaid prints it as a Mermaid flowchart instead of JSON.
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
merge_lists() { python3 -I -c '
import json, sys
out = []
for line in sys.stdin:
    if line.strip(): out.extend(json.loads(line))
print(json.dumps(out))'; }
# A graph from a list that failed is wrong, so a graph lets the adapters' errors through (a
# GitHub list cut at github.limit says so) and stops when one fails. The board shows what it can.
if [ -n "$graph" ]; then
  lists="$(for a in $(adapters_configured); do adapter list "$a" || exit 1; done)" || die "an adapter could not list its items, so no graph" 1
  case "$graph" in priorities) set -- priorities ;; *) set -- epic "$graph" ;; esac
  printf '%s\n' "$lists" | merge_lists | python3 -I "$FLOW_PLUGIN/scripts/_graph.py" "$@" $mermaid
  exit
fi
items="$(for a in $(adapters_configured); do adapter list "$a" 2>/dev/null; done | merge_lists)"
# Each run record says whether a process still holds it: "running on shell" is only true then.
grace="$(python3 -I "$FLOW_PLUGIN/scripts/_health.py" seconds jobs.health.grace "$(cfg_or jobs.health.grace 10m)")" || exit 2
reminder="$(python3 -I "$FLOW_PLUGIN/scripts/_health.py" seconds jobs.health.gate_reminder "$(cfg_or jobs.health.gate_reminder 24h)")" || exit 2
procs="$(mktemp)"; trap 'rm -f "$procs"' EXIT
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
printf '%s\n%s\n%s\n' "$items" "$runs" "$gates" | python3 -I "$FLOW_PLUGIN/scripts/_board.py" "$as_json" "$pool" "$reminder"
