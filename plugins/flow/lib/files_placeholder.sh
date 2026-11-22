#!/bin/sh
# The {files} placeholder of a configured command. POSIX sh. Copied into each plugin that runs shell
# by tools/generate.sh; edit shared/sh/files_placeholder.sh. A command is the project's own text; the
# names are data. files_placeholder_expanded rewrites {files} outside quotes to "$@" and inside
# quotes to $format_names_escaped, so the caller runs the result as
#   format_names_escaped="$(names_backslash_escaped "$@")" sh -c "$expanded" sh "$@"
# and the names reach the command as separate arguments, or, inside quotes, as words with every
# character that is not a letter, digit or one of _ . / - backslash-escaped. A name with a newline
# cannot be escaped: names_backslash_escaped then fails.

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

names_backslash_escaped() {
  for escape_all_name in "$@"; do
    escape_all_one="$(backslash_escape_name_failing_on_newline "$escape_all_name")" || return 1
    printf ' %s' "$escape_all_one"
  done
}

files_placeholder_expanded() {
  expand_rest="$1"; expand_state=none; expand_result=""
  while [ -n "$expand_rest" ]; do
    case "$expand_state:$expand_rest" in
      none:'{files}'*) expand_result="$expand_result\"\$@\""; expand_rest="${expand_rest#'{files}'}"; continue ;;
      single:'{files}'*) expand_result="$expand_result'\"\$format_names_escaped\"'"; expand_rest="${expand_rest#'{files}'}"; continue ;;
      double:'{files}'*) expand_result="$expand_result\$format_names_escaped"; expand_rest="${expand_rest#'{files}'}"; continue ;;
    esac
    expand_tail="${expand_rest#?}"; expand_character="${expand_rest%"$expand_tail"}"
    case "$expand_state:$expand_character" in
      none:"'") expand_state=single ;;
      none:'"') expand_state=double ;;
      single:"'"|double:'"') expand_state=none ;;
      none:'\'|double:'\')
        expand_result="$expand_result$expand_character"; expand_rest="$expand_tail"
        expand_tail="${expand_rest#?}"; expand_character="${expand_rest%"$expand_tail"}" ;;
    esac
    expand_result="$expand_result$expand_character"; expand_rest="$expand_tail"
  done
  printf '%s' "$expand_result"
}
