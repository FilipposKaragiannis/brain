#!/bin/sh
# Print each name that matches a protected pattern, as "  <name> (matches <pattern>)".
# check-config.sh starts it through xargs -0, so every name arrives as its own argument.
#   protected-files.sh <patterns, one per line, * crossing directories> <name>...
set -u
patterns="$1"
shift
set -f
for name in "$@"; do
  for pattern in $patterns; do
    # shellcheck disable=SC2254
    case "$name" in $pattern) printf '  %s (matches %s)\n' "$name" "$pattern" ;; esac
  done
done
