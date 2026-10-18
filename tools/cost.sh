#!/bin/sh
# Report each plugin's always-on token cost and warn when one is over the budget. The cost is
# what a real session loads: `/context` in a session with only that plugin added, summing the
# plugin's rows (the descriptions of its agents and of the skills Claude can start itself). A
# user-invoked skill (disable-model-invocation) loads nothing until it runs, so it costs 0 here;
# `claude plugin details` counts it anyway, which is why this does not use it. Claude only.
# Never fails: without the claude CLI, or when /context prints no rows for the plugin, it skips
# quietly. About five seconds per plugin.
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
root="$PWD"
empty="$(mktemp -d)" || exit 0
trap 'rm -rf "$empty"' EXIT
for dir in plugins/*/; do
  [ -f "$dir/plugin.source.json" ] || continue
  plugin="$(basename "$dir")"
  if [ -n "$only" ]; then case " $only " in *" $plugin "*) ;; *) continue ;; esac; fi
  # From an empty folder, so no project settings add plugins or rows of their own.
  context="$(cd "$empty" && claude --plugin-dir "$root/$dir" -p /context 2>/dev/null)" || continue
  tokens="$(printf '%s\n' "$context" | python3 -c '
import re, sys
plugin, seen, total = sys.argv[1], set(), 0
for line in sys.stdin:
    m = re.match(r"\|\s*%s:([\w.-]+)\s*\|[^|]*\|\s*~?([0-9][0-9,]*(?:\.[0-9]+)?)\s*(k?)\s*\|" % re.escape(plugin), line)
    if m and m.group(1) not in seen:
        seen.add(m.group(1))
        total += int(float(m.group(2).replace(",", "")) * (1000 if m.group(3) else 1))
if seen:
    print(total)
' "$plugin" 2>/dev/null)"
  [ -n "$tokens" ] || continue
  if [ "$tokens" -gt "$budget" ]; then
    echo "cost: warning: $plugin always-on ~$tokens tok, over the $budget budget"
  else
    echo "cost: $plugin always-on ~$tokens tok"
  fi
done
exit 0
