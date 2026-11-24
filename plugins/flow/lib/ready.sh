#!/bin/sh
# The ready: policy of .flow/config.yaml beside ready.needs and ready.priority_order: which
# tracker categories and which assignees leave an unheld item free for the flow to take. Sourced
# by lib/flow.sh; defines functions and runs nothing.
#   ready_policy    exports READY_ASSIGNEE (ready.assignee: none, me, any, a login or an email,
#                   one or a list; default none,me) and READY_CATEGORIES (ready.categories: todo
#                   and unknown, one or a list; default todo,unknown), each comma-separated. The
#                   default stands only for a key the file leaves out. Refuses, exit 2, a category
#                   outside the two, an assignee with a space or a comma, and a key written empty.

READY_CATEGORY_NAMES="todo unknown"
READY_ASSIGNEE_DEFAULT="none,me"
READY_CATEGORIES_DEFAULT="todo,unknown"

ready_policy() {
  READY_CATEGORIES="$(ready_key_values ready.categories "$READY_CATEGORIES_DEFAULT" ready_category_known)" || exit
  READY_ASSIGNEE="$(ready_key_values ready.assignee "$READY_ASSIGNEE_DEFAULT" ready_assignee_shaped)" || exit
  export READY_ASSIGNEE READY_CATEGORIES
}

ready_key_values() (
  if [ -z "$(yaml_line "$(config_file)" "$1")" ]; then printf '%s' "$2"; exit 0; fi
  ready_values="$(cfg "$1")"
  [ -n "$ready_values" ] \
    || die "$1 is written empty: leave the key out for the default, $(printf '%s' "$2" | sed 's/,/ and /g')" "$EXIT_USAGE"
  while IFS= read -r ready_value; do "$3" "$1" "$ready_value"; done <<EOF
$ready_values
EOF
  printf '%s\n' "$ready_values" | paste -sd, -
)

ready_category_known() {
  case "$2" in
    *[[:space:]]*) ;;
    *) case " $READY_CATEGORY_NAMES " in *" $2 "*) return 0 ;; esac ;;
  esac
  die "$1 takes $(printf '%s' "$READY_CATEGORY_NAMES" | sed 's/ / and /g'), not $2" "$EXIT_USAGE"
}

ready_assignee_shaped() {
  case "$2" in
    *[[:space:],]*) die "$1 takes none, me, any, a login or an email, each without a space or a comma, not '$2'" "$EXIT_USAGE" ;;
  esac
}
