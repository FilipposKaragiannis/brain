#!/bin/sh
# The {files} placeholder of a configured command. POSIX sh. Copied into each plugin that runs shell
# by tools/generate.sh; edit shared/sh/files_placeholder.sh. A command is the project's own text; the
# names are data. files_placeholder_expanded rewrites a {files} that is an argument word of its own
# outside quotes to "$@", and one that is an unquoted argument word in the quoted script of a
# sh -c or bash -c that starts a command to $format_names_escaped, so the caller runs the result as
#   format_names_escaped="$(names_backslash_escaped "$@")" sh -c "$expanded" sh "$@"
# and the names reach the command as separate arguments, or, in the script, as words with every
# character that is not a letter, digit or one of _ . / - backslash-escaped. A name with a newline
# cannot be escaped: names_backslash_escaped then fails. Anywhere else, or after a construct the
# scanner does not follow ($( ${ $' $" a backtick, # or <<), or in a command that leaves a quote
# open, files_placeholder_expanded says why on stderr and fails, so a name is never read as shell.

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

files_placeholder_refused() {
  echo "{files} must be an argument word of its own, outside quotes or unquoted in the quoted script of a sh -c or bash -c that starts a command, with no \$( \${ \$' \$\" backtick, # or << before it and no quote left open; here it sits in nested quotes, joins other text or is not certain to be data. Pass the names on as arguments: sh -c '... \"\$@\"' sh {files}" >&2
  return 1
}

files_placeholder_begins_with_word_end() {
  case "$1" in [' ;|&']*|'
'*) return 0 ;; esac
  return 1
}

files_placeholder_begins_unfollowed_unquoted() {
  case "$1" in '$('*|'${'*|"\$'"*|'$"'*|'$\'*|'`'*|'#'*|'<<'*) return 0 ;; esac
  return 1
}

files_placeholder_begins_unfollowed_in_double() {
  case "$1" in '$('*|'${'*|'$\'*|'`'*) return 0 ;; esac
  return 1
}

files_placeholder_unquoted_after() {
  files_placeholder_begins_unfollowed_unquoted "$1" && { printf unsure; return 0; }
  case "$1" in ' '*) printf edge ;; *) printf none ;; esac
}

files_placeholder_opened() {
  case "$1" in \'*) printf single ;; *) printf double ;; esac
  if files_placeholder_ends_with_a_script_shell "$2"; then printf ' none'; else printf ' -'; fi
}

files_placeholder_ends_with_a_script_shell() {
  case "$1" in
    "sh -c "|*[';|&(']"sh -c "|*[';|&(']" sh -c ") return 0 ;;
    "bash -c "|*[';|&(']"bash -c "|*[';|&(']" bash -c ") return 0 ;;
  esac
  return 1
}

files_placeholder_after_outside_quotes() {
  case "$1" in unsure*) printf 'unsure -'; return 0 ;; none_escaped*) printf 'none -'; return 0 ;; esac
  case "$2" in
    \\*) printf 'none_escaped -' ;;
    [\'\"]*) files_placeholder_opened "$2" "$3" ;;
    *) files_placeholder_unquoted_after "$2"; printf ' -' ;;
  esac
}

files_placeholder_script_after_unquoted() {
  case "$1" in
    \\*) printf none_escaped ;;
    \'*) printf single ;;
    \"*) printf double ;;
    *) files_placeholder_unquoted_after "$1" ;;
  esac
}

files_placeholder_script_after_in_double() {
  files_placeholder_begins_unfollowed_in_double "$1" && { printf unsure; return 0; }
  case "$1" in
    \\*) printf double_escaped ;;
    \"*) printf none ;;
    *) printf double ;;
  esac
}

files_placeholder_script_after_in_single() {
  case "$1" in \'*) printf none ;; *) printf single ;; esac
}

files_placeholder_script_after() {
  case "$1" in
    edge|none) files_placeholder_script_after_unquoted "$2" ;;
    single) files_placeholder_script_after_in_single "$2" ;;
    double) files_placeholder_script_after_in_double "$2" ;;
    none_escaped|double_escaped) printf '%s' "${1%_escaped}" ;;
    *) printf '%s' "$1" ;;
  esac
}

files_placeholder_after_in_single() {
  case "$2" in
    \'*) printf 'none -' ;;
    *) printf 'single '; files_placeholder_script_after "$1" "$2" ;;
  esac
}

files_placeholder_after_in_double() {
  files_placeholder_begins_unfollowed_in_double "$2" && { printf 'unsure -'; return 0; }
  case "$2" in
    \"*) printf 'none -' ;;
    \\*) printf 'double_escaped %s' "$1" ;;
    \$*) printf 'double unsure' ;;
    *) printf 'double '; files_placeholder_script_after "$1" "$2" ;;
  esac
}

files_placeholder_after_escape_in_double() {
  case "$2" in
    '
'*) printf 'unsure -' ;;
    [\$\`\"\\]*) printf 'double '; files_placeholder_script_after "$1" "$2" ;;
    *) printf 'double '; files_placeholder_script_after "$(files_placeholder_script_after "$1" "\\$2")" "$2" ;;
  esac
}

files_placeholder_state_after() {
  case "$1" in
    "single "*) files_placeholder_after_in_single "${1#* }" "$2" ;;
    "double "*) files_placeholder_after_in_double "${1#* }" "$2" ;;
    "double_escaped "*) files_placeholder_after_escape_in_double "${1#* }" "$2" ;;
    *) files_placeholder_after_outside_quotes "$1" "$2" "$3" ;;
  esac
}

files_placeholder_follows_an_argument() {
  files_placeholder_word="${1%"${1##*[! ]}"}"; files_placeholder_word="${files_placeholder_word##*[' ;|&()<>
']}"
  case "${files_placeholder_word#[\'\"]}" in
    ''|'!'|'{'|do|then|else|elif|if|while|until|time|exec|[A-Za-z_]*=*) return 1 ;;
  esac
}

files_placeholder_ends_a_word() {
  files_placeholder_after_word="${2#"$1"}"
  [ -z "$files_placeholder_after_word" ] || files_placeholder_begins_with_word_end "$files_placeholder_after_word"
}

files_placeholder_step_when_word_ends() {
  files_placeholder_ends_a_word "$1" "$2" && printf '%s' "$3"
}

files_placeholder_for_state() {
  case "$1" in
    "edge -") files_placeholder_step_when_word_ends "" "$2" 'none -:"$@"' ;;
    "single edge") files_placeholder_step_when_word_ends "'" "$2" "single none:'\"\$format_names_escaped\"'" ;;
    "double edge") files_placeholder_step_when_word_ends '"' "$2" 'double none:$format_names_escaped' ;;
    *) return 1 ;;
  esac
}

files_placeholder_over_files() {
  if files_placeholder_follows_an_argument "$3" && files_placeholder_for_state "$1" "$2"; then return 0; fi
  files_placeholder_refused
}

files_placeholder_closed() {
  case "$1" in "edge -"|"none -"|"unsure -") return 0 ;; esac
  files_placeholder_refused
}

files_placeholder_expanded() {
  expand_rest="$1"; expand_state="none -"; expand_result=""
  while [ -n "$expand_rest" ]; do
    case "$expand_rest" in
      '{files}'*)
        expand_rest="${expand_rest#'{files}'}"
        expand_step="$(files_placeholder_over_files "$expand_state" "$expand_rest" "$expand_result")" || return 1
        expand_state="${expand_step%%:*}"; expand_result="$expand_result${expand_step#*:}" ;;
      *)
        expand_state="$(files_placeholder_state_after "$expand_state" "$expand_rest" "$expand_result")"
        expand_tail="${expand_rest#?}"; expand_result="$expand_result${expand_rest%"$expand_tail"}"; expand_rest="$expand_tail" ;;
    esac
  done
  files_placeholder_closed "$expand_state" && printf '%s' "$expand_result"
}
