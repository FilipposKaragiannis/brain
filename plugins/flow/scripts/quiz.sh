#!/bin/sh
# The owner's quiz on a change, written by the explain step as <reports>/quiz.md and taken in
# the console (or here).
#   quiz.sh show <item>                 the quiz as JSON: title, questions with their choices,
#                                       the answer key and the Because line, and the last
#                                       result (<reports>/quiz.json) or null
#   quiz.sh answer <item> <answers...>  grade the answers: "1b 2a 3c", or "b a c" in question
#                                       order. Writes <reports>/quiz.json, logs one events.log
#                                       line, and on a pass marks the item's draft PR ready
#                                       (comments.sh ready) when it has one on GitHub.
# Exit 0 on a pass or a fail alike (the result says which); 2 on a bad call or no quiz; 1 when
# the result could not be written.
. "$(dirname "$0")/../lib/flow.sh"
home="$(flow_home)"

reports_of() { "$FLOW_PLUGIN/scripts/steward.sh" reports "$1"; }
is_pr() { # is_pr <value>: a PR number, or a GitHub PR URL that ends in one
  number="${1##*/}"
  case "$number" in ""|*[!0-9]*) return 1 ;; esac
  case "$1" in "$number"|https://github.com/*/pull/"$number") return 0 ;; esac
  return 1
}
mark_ready() { # mark_ready <item>: marks the item's draft PR ready and prints the note for the pass line,
  # nothing when the item has no PR on GitHub
  pr="$(state_get "$(adapter read "$1" 2>/dev/null)" pr)"
  [ -n "$pr" ] && [ -n "$(cfg github.repo)" ] || return 0
  is_pr "$pr" || { echo "; the PR in the state is not a PR number or URL, so it was not marked ready"; return 0; }
  if "$FLOW_PLUGIN/scripts/comments.sh" ready "$pr" >/dev/null 2>&1; then echo "; PR $pr marked ready for review"
  else echo "; PR $pr could not be marked ready (comments.sh ready $pr)"; fi
}

case "${1:-}" in
  show)
    [ $# -eq 2 ] || die "usage: quiz.sh show <item>" 2
    item="$2"; reports="$(reports_of "$item")" || exit 2
    [ -s "$reports/quiz.md" ] || die "no quiz for $item ($reports/quiz.md)" 2
    quiz="$(python3 -I "$FLOW_PLUGIN/scripts/_quiz.py" parse "$reports/quiz.md")" || die "cannot parse $reports/quiz.md" 2
    result=null; [ -s "$reports/quiz.json" ] && result="$(cat "$reports/quiz.json")"
    printf '%s\n' "$(json_set "$(json_set "$quiz" item "$(json_string "$item")")" result "$result")" ;;
  answer)
    [ $# -ge 3 ] || die "usage: quiz.sh answer <item> <answers...>  (1b 2a 3c, or b a c)" 2
    item="$2"; shift 2
    reports="$(reports_of "$item")" || exit 2
    [ -s "$reports/quiz.md" ] || die "no quiz for $item ($reports/quiz.md)" 2
    result="$(python3 -I "$FLOW_PLUGIN/scripts/_quiz.py" grade "$reports/quiz.md" "$@")" || die "cannot grade $reports/quiz.md" 2
    at="$(now_iso)"
    result="$(json_set "$(json_set "$result" item "$(json_string "$item")")" at "$(json_string "$at")")"
    printf '%s\n' "$result" > "$reports/quiz.json" || die "cannot write $reports/quiz.json"
    right="$(json_get "$result" right)"; total="$(json_get "$result" total)"; passed="$(json_get "$result" passed)"
    verdict="failed"; [ "$passed" = true ] && verdict="passed"
    mkdir -p "$home"; printf '%s\t%s\tquiz\t%s %s/%s\n' "$at" "$item" "$verdict" "$right" "$total" >> "$home/events.log"
    note=""; [ "$passed" = true ] && note="$(mark_ready "$item")"
    echo "quiz $verdict on $item: $right of $total right$note"
    printf '%s\n' "$result" ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
