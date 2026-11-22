#!/bin/sh
# Print each name that matches a protected pattern, as "  <name> (matches <pattern>)".
# check-config.sh and check-gates.sh start it through xargs -0, so every name arrives as its own
# argument.
#   protected-files.sh <patterns, one per line, * crossing directories> <name>...
set -u

print_each_pattern_the_name_matches() {
  for print_pattern in $2; do
    # shellcheck disable=SC2254
    case "$1" in $print_pattern) printf '  %s (matches %s)\n' "$1" "$print_pattern" ;; esac
  done
}

patterns="$1"
shift
set -f
for name in "$@"; do
  print_each_pattern_the_name_matches "$name" "$patterns"
done
