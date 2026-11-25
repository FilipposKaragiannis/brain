#!/bin/sh
# The tracker's status and assignee follow the flow record (adapters/README.md, set-status and
# assign). Sourced by lib/flow.sh after lib/state.sh; defines functions and runs nothing. Neither
# public function changes a variable of its caller or reads its stdin, and each returns 0: the
# tracker's card is a view of the record, so a tracker that fails warns once on stderr, leaves one
# events.log line (push failed) and never fails the step.
#   tracker_push <item>         adapter set-status with the status the record stands for
#                               (scripts/_state_schema.py pushed_status); nothing with no claim. A
#                               push that lands is recorded as pushed:={status, at}. It never skips
#                               on pushed, so a card moved by hand comes back on the next push; the
#                               adapter's idempotence keeps a card from moving twice
#   tracker_take <item> <new|held>
#                               after take_item: on a claim the take made (new), adapter assign
#                               <item> me when the item has no assignee, recording
#                               claim.assigned_at only when the adapter says it assigned, then
#                               tracker_push. A claim held before the take (held) costs no tracker
#                               call
# Called after the record write it follows returns, outside the record's lock.

tracker_push() (
  [ $# -eq 1 ] || die "usage: tracker_push <item>" "$EXIT_USAGE"
  flow_push_status="$(state_python status "$(state_dir)" "$(flow_home)" "$1" </dev/null 2>&1)" \
    || { tracker_failed "$1" "set-status" "$flow_push_status"; exit 0; }
  [ -n "$flow_push_status" ] || exit 0
  flow_push_said="$( (adapter set-status "$1" "$flow_push_status") </dev/null 2>&1 >/dev/null)" \
    || { tracker_failed "$1" "set-status $flow_push_status" "$flow_push_said"; exit 0; }
  record_set "$1" "pushed:=$(json_obj "status=$flow_push_status" "at=$(now_iso)")" </dev/null \
    || echo "flow: $1 is $flow_push_status on its tracker, but its flow record could not say so" >&2
  exit 0
)

tracker_take() (
  [ $# -eq 2 ] || die "usage: tracker_take <item> <new|held>" "$EXIT_USAGE"
  case "$2" in
    new) ;;
    held) exit 0 ;;
    *) die "tracker_take: the claim is new or held, not $2" "$EXIT_USAGE" ;;
  esac
  tracker_assign "$1"
  tracker_push "$1"
)

# tracker_assign <item>: adapter assign <item> me when the item has no assignee, then
# claim.assigned_at when the adapter printed the item, which it does only when it assigned. A
# tracker that fails is tracker_failed's.
tracker_assign() (
  flow_push_item="$( (adapter read "$1") </dev/null 2>/dev/null)" \
    || { tracker_failed "$1" "assign me" "the item's read failed"; exit 0; }
  [ "$(json_length "$flow_push_item" assignees)" = 0 ] || exit 0
  flow_push_assign_said="$( (adapter assign "$1" me) </dev/null 2>&1)" \
    || { tracker_failed "$1" "assign me" "$flow_push_assign_said"; exit 0; }
  printf '%s\n' "$flow_push_assign_said" | awk -v item="$1" '$1 == item { assigned = 1 } END { exit !assigned }' \
    || exit 0
  record_set "$1" "claim.assigned_at=$(now_iso)" </dev/null \
    || echo "flow: $1 is assigned to you on its tracker, but its flow record could not say so" >&2
)

# tracker_failed <item> <operation> <what the tracker said>: the one stderr warning and the one
# events.log line of a tracker operation that failed, with the last line the tracker said.
tracker_failed() (
  flow_push_reason="$(printf '%s\n' "$3" | sed '/^[[:space:]]*$/d' | tail -n 1 | tr '\t' ' ')"
  flow_push_reason="${flow_push_reason:-no reason given}"
  echo "flow: $1: $2 failed on its tracker ($flow_push_reason); the step goes on" >&2
  printf '%s\t%s\tpush failed\t%s: %s\n' "$(now_iso)" "$1" "$2" "$flow_push_reason" >> "$(flow_home)/events.log"
)
