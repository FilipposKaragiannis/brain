#!/bin/sh
# Report each plugin's always-on token cost (the skill and agent descriptions every session
# carries) from `claude plugin details`, and warn when one is over the budget. Never fails:
# without the claude CLI, or when its output has no "Always-on: ~N tok" line, it skips quietly.
#   tools/cost.sh [plugin...] [budget]   every plugin unless named; the budget is tokens per
#   plugin, default 2000 (or BRAIN_ALWAYS_ON_BUDGET). A number is the budget, a word a plugin.
set -u
cd "$(dirname "$0")/.."
budget="${BRAIN_ALWAYS_ON_BUDGET:-2000}"; only=""
for arg in "$@"; do
  case "$arg" in
    *[!0-9]*|'') [ -f "plugins/$arg/plugin.source.json" ] || { echo "cost: no plugin named $arg" >&2; exit 2; }
                 only="$only $arg" ;;
    *) budget="$arg" ;;
  esac
done
command -v claude >/dev/null 2>&1 || exit 0
for dir in plugins/*/; do
  [ -f "$dir/plugin.source.json" ] || continue
  plugin="$(basename "$dir")"
  if [ -n "$only" ]; then case " $only " in *" $plugin "*) ;; *) continue ;; esac; fi
  details="$(claude --plugin-dir "$dir" plugin details "$plugin" 2>/dev/null)" || continue
  tokens="$(printf '%s\n' "$details" | python3 -c '
import re, sys
m = re.search(r"Always-on:\s*~?([0-9][0-9,]*(?:\.[0-9]+)?)\s*(k?)\s*tok", sys.stdin.read())
if m:
    print(int(float(m.group(1).replace(",", "")) * (1000 if m.group(2) else 1)))
' 2>/dev/null)"
  [ -n "$tokens" ] || continue
  if [ "$tokens" -gt "$budget" ]; then
    echo "cost: warning: $plugin always-on ~$tokens tok, over the $budget budget"
  else
    echo "cost: $plugin always-on ~$tokens tok"
  fi
done
exit 0
