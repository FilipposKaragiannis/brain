#!/bin/sh
# map.sh [--roster <roster.json>] [--out <file>]: render the brain map to a file (default
# .scratch/map.html). With --roster, a project's own agents (project.roster in
# .standards/config.json) show beside the plugin agents. The committed docs/map.html is the
# plugin-only page, rendered by tools/generate.sh; this one is for the reader, never committed.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
out="$here/.scratch/map.html"; roster=""
while [ $# -gt 0 ]; do
  case "$1" in
    --roster) roster="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2 ;;
    --out) out="$(cd "$(dirname "$2")" 2>/dev/null && pwd || dirname "$2")/$(basename "$2")"; shift 2 ;;
    *) echo "usage: tools/map.sh [--roster <roster.json>] [--out <file>]" >&2; exit 2 ;;
  esac
done
mkdir -p "$(dirname "$out")"
if [ -n "$roster" ]; then python3 "$here/tools/lib/map.py" --roster "$roster" > "$out"; else python3 "$here/tools/lib/map.py" > "$out"; fi
echo "map: wrote $out"
