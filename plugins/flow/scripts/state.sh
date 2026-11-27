#!/bin/sh
# The flow record of an item: one JSON file per item under state.dir (lib/state.sh).
#   state.sh get <item> <key>       one of the twenty-one state keys through the key map, or a record
#                                   path (gate.options.0.label, claim.machine, run); a string raw,
#                                   anything else as JSON, nothing when there is no record
#   state.sh set <item> <pair>...   record_set: key=value for the state keys, or run:=<object|null>,
#                                   run.step=<text>, gate:=<object>, pushed:=<object|null> and
#                                   claim.assigned_at=<text>; with tracker_state labels the state
#                                   pairs reach the tracker first
#   state.sh show <item>            the record as JSON; exit 1 with none
#   state.sh path <item>            where the record lives while the item is open
#   state.sh archive <item>         the record to closed/; refused, exit 1, while another
#                                   machine holds the item
#   state.sh read <item>            item_read: the adapter's read with the record joined on as
#                                   state and stamped state_from (record or tracker)
#   state.sh join                   items_join: the item, or array of items, on stdin, joined
#   state.sh list runs|gates [<item>]
#                                   record_list: one compact row per line of each run in flight or
#                                   gate raised, or of the one item
#   state.sh import [--dry-run] [--strip]
#                                   state_import (lib/migrate.sh): a record for each open item of
#                                   every configured tracker whose tracker state carries flow state
#                                   and that has none, seeded as the first write would seed it. An
#                                   item whose worktree no claim.json here names is skipped and
#                                   said; one with a step or a worktree is held here, assigned and
#                                   its status pushed. --strip then takes the flow state and labels
#                                   off the tracker of each item recorded here; refused, exit 2,
#                                   under tracker_state labels. --dry-run says what it would do and
#                                   changes nothing. Exit 1 when a list, a record write or a strip
#                                   failed, after the rest ran; the same call again is safe
# An id that is not of its adapter's shape is refused, exit 2.
# Exit codes: 0 done · 1 refused or unreadable record · 2 bad usage · 75 the item's lock stayed
# busy · the adapter's code when the tracker refused a write or its read failed.
. "$(dirname "$0")/../lib/flow.sh"
. "$FLOW_PLUGIN/lib/migrate.sh"

usage() { awk '/^#!/ { next } /^#/ { print; next } { exit }' "$0"; exit "$EXIT_USAGE"; }

import_done() {
  import_effect="write"; import_strip="keep"
  for import_option in "$@"; do
    case "$import_option" in
      --dry-run) import_effect="plan" ;;
      --strip) import_strip="strip" ;;
      *) usage ;;
    esac
  done
  state_import "$import_effect" "$import_strip"
}

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
  import:*) import_done "$@" ;;
  *) usage ;;
esac
