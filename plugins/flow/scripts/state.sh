#!/bin/sh
# The flow record of an item: one JSON file per item under state.dir (lib/state.sh).
#   state.sh get <item> <key>       one of the twenty state keys through the key map, or a record
#                                   path (gate.options.0.label, claim.machine, run); a string raw,
#                                   anything else as JSON, nothing when there is no record
#   state.sh set <item> <pair>...   record_set: key=value for the state keys, or run:=<object|null>,
#                                   run.step=<text> and gate:=<object>; with tracker_state labels
#                                   the state pairs reach the tracker first
#   state.sh show <item>            the record as JSON; exit 1 with none
#   state.sh path <item>            where the record lives while the item is open
#   state.sh archive <item>         the record to closed/; refused, exit 1, while another
#                                   machine holds the item
#   state.sh read <item>            item_read: the adapter's read with the record joined on as
#                                   state and stamped state_from (record, tracker or none)
#   state.sh join                   items_join: the item, or array of items, on stdin, joined
#   state.sh list runs|gates [<item>]
#                                   record_list: one compact row per line of each run in flight or
#                                   gate raised, or of the one item
# An id that is not of its adapter's shape is refused, exit 2.
# Exit codes: 0 done · 1 refused or unreadable record · 2 bad usage · 75 the item's lock stayed
# busy · the adapter's code when the tracker refused a write or its read failed.
. "$(dirname "$0")/../lib/flow.sh"

command="${1:-}"; [ $# -gt 0 ] && shift
case "$command:$#" in
  get:2) record_get "$1" "$2" ;;
  set:*) [ $# -ge 2 ] || die "usage: state.sh set <item> <key=value>..." "$EXIT_USAGE"; record_set "$@" ;;
  show:1) record_show "$1" ;;
  path:1) item_shape_required "$1"; record_file "$1"; echo ;;
  archive:1) record_archive "$1" ;;
  read:1) item_read "$1" ;;
  join:0) items_join ;;
  list:1|list:2) record_list "$@" ;;
  *) awk '/^#!/ { next } /^#/ { print; next } { exit }' "$0"; exit "$EXIT_USAGE" ;;
esac
