#!/bin/sh
# board.sh [--json] [--graph <epic-id>]: every adapter, every claim. The pool with item, step and
# last event; open items with their state and blockers; pending gates; overlapping claims.
# --graph prints the dependency model of a GitHub epic (scripts/epic_graph.py).
. "$(dirname "$0")/../lib/flow.sh"
home="$(flow_home)"
as_json=0; graph=""
while [ $# -gt 0 ]; do
  case "$1" in --json) as_json=1; shift ;; --graph) graph="$2"; shift 2 ;; *) die "unknown option $1" 2 ;; esac
done
if [ -n "$graph" ]; then
  case "$graph" in gh#*) ;; *) die "--graph takes a GitHub epic id (gh#N)" 2 ;; esac
  repo="$(cfg github.repo)"; [ -n "$repo" ] || repo="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
  exec python3 -I "$FLOW_PLUGIN/scripts/epic_graph.py" "$repo" "${graph#gh#}"
fi
items="$(for a in $(adapters_configured); do adapter list "$a" 2>/dev/null; done | python3 -I -c '
import json, sys
out = []
for line in sys.stdin:
    if line.strip(): out.extend(json.loads(line))
print(json.dumps(out))')"
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
