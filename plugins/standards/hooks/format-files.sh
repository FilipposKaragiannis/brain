#!/bin/sh
# Run one formatter command over the names that sit under a prefix and end in one of the
# extensions. check-format.sh starts it through xargs -0, so every name arrives as its own argument.
#   format-files.sh <prefix> <extensions, one per line> <command> <name>...
# The command is the project's own text from .standards/config.json, with {files} already written
# as "$@"; it runs as `sh -c <command> sh <kept names>`. Exit 0 when no name is kept.
set -u
prefix="$1"; extensions="$2"; command="$3"
shift 3
remaining=$#
while [ "$remaining" -gt 0 ]; do
  name="$1"; shift; remaining=$((remaining - 1))
  case "$name" in "$prefix"*) ;; *) continue ;; esac
  for extension in $extensions; do
    case "$name" in *"$extension") set -- "$@" "$name"; break ;; esac
  done
done
[ "$#" -gt 0 ] || exit 0
exec sh -c "$command" sh "$@"
