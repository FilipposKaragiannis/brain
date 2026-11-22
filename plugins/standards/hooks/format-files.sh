#!/bin/sh
# Run one formatter command from .standards/config.json over the names that sit under a prefix and
# end in one of the extensions, each name its own argument, quoted {files} included. Exit 0 when no
# name is kept; on failure, list the kept names. check-format.sh starts it through xargs -0.
#   format-files.sh <prefix> <extensions, one per line> <command> <name>...
set -u
. "$(dirname "$0")/files_placeholder.sh"

name_is_under_prefix_with_one_of_extensions() {
  case "$3" in "$1"*) ;; *) return 1 ;; esac
  for matched_extension in $2; do
    case "$3" in *"$matched_extension") return 0 ;; esac
  done
  return 1
}

escaped_names_when_command_quotes_files() {
  case "$1" in *format_names_escaped*) ;; *) return 0 ;; esac
  shift
  names_backslash_escaped "$@"
}

prefix="$1"; shift
extensions="$1"; shift
command="$1"; shift
remaining=$#
while [ "$remaining" -gt 0 ]; do
  name="$1"; shift; remaining=$((remaining - 1))
  name_is_under_prefix_with_one_of_extensions "$prefix" "$extensions" "$name" && set -- "$@" "$name"
done
[ "$#" -gt 0 ] || exit 0
run="$(files_placeholder_expanded "$command")" || exit 1
names_escaped="$(escaped_names_when_command_quotes_files "$run" "$@")" \
  || { echo "a file name with a newline cannot go into a quoted {files}" >&2; exit 1; }
format_names_escaped="$names_escaped" sh -c "$run" sh "$@" && exit 0
status=$?
printf '  files:\n'
printf '    %s\n' "$@"
exit "$status"
