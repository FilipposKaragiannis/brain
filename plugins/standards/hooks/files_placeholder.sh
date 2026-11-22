#!/bin/sh
# The {files} placeholder of a configured command. POSIX sh. Copied into each plugin that runs shell
# by tools/generate.sh; edit shared/sh/files_placeholder.sh. A command is the project's own text; the
# names are data. files_placeholder_expanded rewrites {files} outside quotes to "$@" and inside
# quotes to $format_names_escaped, so the caller runs the result as
#   format_names_escaped="$(names_backslash_escaped "$@")" sh -c "$expanded" sh "$@"
# and the names reach the command as separate arguments, or, inside quotes, as words with every
# character that is not a letter, digit or one of _ . / - backslash-escaped. A name with a newline
# cannot be escaped: names_backslash_escaped then fails. A {files} inside a quote that sits inside
# another quote would be read by two shells, so escaping cannot keep it data: files_placeholder_expanded
# then fails, and the command should hand the names on as arguments, sh -c '... "$@"' sh {files}.

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

quote_state_after_unquoted() {
  case "$1" in
    "'") printf single ;;
    '"') printf double ;;
    *) printf none ;;
  esac
}

quote_state_after_in_single() {
  case "$1:$2" in
    *:"'") printf none ;;
    single:'"') printf single_inner ;;
    single_inner:'"') printf single ;;
    *) printf '%s' "$1" ;;
  esac
}

quote_state_after_in_double() {
  case "$1:$2" in
    *:'"') printf none ;;
    double:"'") printf double_inner_single ;;
    double_inner_single:"'") printf double ;;
    *) printf '%s' "$1" ;;
  esac
}

quote_state_after() {
  case "$1" in
    none) quote_state_after_unquoted "$2" ;;
    single*) quote_state_after_in_single "$1" "$2" ;;
    *) quote_state_after_in_double "$1" "$2" ;;
  esac
}

quote_state_after_escaped() {
  case "$1:$2" in
    double:'"') printf double_inner_escaped ;;
    double_inner_escaped:'"') printf double ;;
    single_inner:"'") printf none ;;
    *) printf '%s' "$1" ;;
  esac
}

begins_an_escape() {
  case "$1" in none|double|double_inner_escaped|single_inner) [ "$2" = '\' ] && return 0 ;; esac
  return 1
}

files_placeholder_for_quote_state() {
  case "$1" in
    none) printf '"$@"' ;;
    single) printf '%s' "'\"\$format_names_escaped\"'" ;;
    double) printf '%s' '$format_names_escaped' ;;
    *) return 1 ;;
  esac
}

files_placeholder_expanded() {
  expand_rest="$1"; expand_state=none; expand_result=""
  while [ -n "$expand_rest" ]; do
    case "$expand_rest" in
      '{files}'*)
        expand_placeholder="$(files_placeholder_for_quote_state "$expand_state")" || return 1
        expand_result="$expand_result$expand_placeholder"
        expand_rest="${expand_rest#'{files}'}"; continue ;;
    esac
    expand_tail="${expand_rest#?}"; expand_character="${expand_rest%"$expand_tail"}"
    if begins_an_escape "$expand_state" "$expand_character"; then
      expand_result="$expand_result$expand_character"; expand_rest="$expand_tail"
      expand_tail="${expand_rest#?}"; expand_character="${expand_rest%"$expand_tail"}"
      expand_state="$(quote_state_after_escaped "$expand_state" "$expand_character")"
    else
      expand_state="$(quote_state_after "$expand_state" "$expand_character")"
    fi
    expand_result="$expand_result$expand_character"; expand_rest="$expand_tail"
  done
  printf '%s' "$expand_result"
}
