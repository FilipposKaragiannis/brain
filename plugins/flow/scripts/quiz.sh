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
    note=""
    if [ "$passed" = true ]; then
      pr="$(state_get "$(adapter read "$item" 2>/dev/null)" pr)"
      if [ -n "$pr" ] && [ -n "$(cfg github.repo)" ]; then
        if "$FLOW_PLUGIN/scripts/comments.sh" ready "$pr" >/dev/null 2>&1; then note="; PR $pr marked ready for review"
        else note="; PR $pr could not be marked ready (comments.sh ready $pr)"; fi
      fi
    fi
    echo "quiz $verdict on $item: $right of $total right$note"
    printf '%s\n' "$result" ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
