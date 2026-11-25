#!/bin/sh
# Print each name that matches one of the patterns, as "  <name> (matches <pattern>)".
# check-config.sh and check-gates.sh start it through xargs -0, one argument per name.
#   files-matching-patterns.sh <patterns, one per line, * crossing directories> <name>...
set -u

print_each_pattern_the_name_matches() {
  for print_pattern in $2; do
    # shellcheck disable=SC2254 # the pattern is a glob
    case "$1" in $print_pattern) printf '  %s (matches %s)\n' "$1" "$print_pattern" ;; esac
  done
}

patterns="$1"
shift
set -f
for name in "$@"; do
  print_each_pattern_the_name_matches "$name" "$patterns"
done
