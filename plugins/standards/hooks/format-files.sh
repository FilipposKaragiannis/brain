#!/bin/sh
# Run one formatter command over the names that sit under a prefix and end in one of the
# extensions. check-format.sh starts it through xargs -0, so every name arrives as its own argument.
#   format-files.sh <prefix> <extensions, one per line> <command> <name>...
# The command is the project's own text from .standards/config.json; it runs as
# `sh -c <command> sh <kept names>`. {files} outside quotes becomes "$@". {files} inside quotes,
# as in `sh -c 'for f in {files}; ...'`, becomes the names with every character that is not a
# letter, digit or one of _ . / - backslash-escaped, so the nested shell reads each name as one
# word and runs none of them. Exit 0 when no name is kept. On failure it lists the kept names.
set -u

name_ends_in_one_of_extensions() {
  for matched_extension in $2; do
    case "$1" in *"$matched_extension") return 0 ;; esac
  done
  return 1
}

backslash_escape_name_failing_on_newline() {
  escape_rest="$1"; escape_result=""
  while [ -n "$escape_rest" ]; do
    escape_tail="${escape_rest#?}"; escape_character="${escape_rest%"$escape_tail"}"
    case "$escape_character" in
      [A-Za-z0-9_./-]) escape_result="$escape_result$escape_character" ;;
      "
") return 1 ;;
      *) escape_result="$escape_result\\$escape_character" ;;
    esac
    escape_rest="$escape_tail"
  done
  printf '%s' "$escape_result"
}

backslash_escape_names_space_separated() {
  for escape_all_name in "$@"; do
    escape_all_one="$(backslash_escape_name_failing_on_newline "$escape_all_name")" || return 1
    printf ' %s' "$escape_all_one"
  done
}

quote_state_after() {
  case "$1:$2" in
    none:"'") printf single ;;
    none:'"') printf double ;;
    single:"'"|double:'"') printf none ;;
    *) printf '%s' "$1" ;;
  esac
}

begins_an_escape() {
  case "$1:$2" in none:'\'|double:'\') return 0 ;; esac
  return 1
}

files_placeholder_for_quote_state() {
  case "$1" in
    none) printf '"$@"' ;;
    single) printf '%s' "'\"\$format_names_escaped\"'" ;;
    double) printf '%s' '$format_names_escaped' ;;
  esac
}

expand_files_placeholder_for_its_quote() {
  expand_rest="$1"; expand_state=none; expand_result=""
  while [ -n "$expand_rest" ]; do
    case "$expand_rest" in
      '{files}'*)
        expand_result="$expand_result$(files_placeholder_for_quote_state "$expand_state")"
        expand_rest="${expand_rest#'{files}'}"; continue ;;
    esac
    expand_tail="${expand_rest#?}"; expand_character="${expand_rest%"$expand_tail"}"
    if begins_an_escape "$expand_state" "$expand_character"; then
      expand_result="$expand_result$expand_character"; expand_rest="$expand_tail"
      expand_tail="${expand_rest#?}"; expand_character="${expand_rest%"$expand_tail"}"
    else
      expand_state="$(quote_state_after "$expand_state" "$expand_character")"
    fi
    expand_result="$expand_result$expand_character"; expand_rest="$expand_tail"
  done
  printf '%s' "$expand_result"
}

prefix="$1"; extensions="$2"; command="$3"
shift 3
remaining=$#
while [ "$remaining" -gt 0 ]; do
  name="$1"; shift; remaining=$((remaining - 1))
  case "$name" in "$prefix"*) ;; *) continue ;; esac
  name_ends_in_one_of_extensions "$name" "$extensions" && set -- "$@" "$name"
done
[ "$#" -gt 0 ] || exit 0
run="$(expand_files_placeholder_for_its_quote "$command")"
names_escaped=""
case "$run" in
  *format_names_escaped*)
    names_escaped="$(backslash_escape_names_space_separated "$@")" || { echo "a file name with a newline cannot go into a quoted {files}" >&2; exit 1; } ;;
esac
format_names_escaped="$names_escaped" sh -c "$run" sh "$@" && exit 0
status=$?
printf '  files:\n'
printf '    %s\n' "$@"
exit "$status"
