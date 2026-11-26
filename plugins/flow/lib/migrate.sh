#!/bin/sh
# Carries the flow state an older flow left on the trackers into the flow records, and takes it
# off them. Sourced by scripts/state.sh only, after lib/flow.sh; defines functions and runs nothing.
# No function here changes a variable of its caller or reads its stdin.
#   state_import <plan|write> <strip|keep>
#     plan says what write would do and changes nothing.
#     strip is refused, exit 2, under tracker_state labels: its mirror would write the state back.
#     Exit 0 done; 1 a tracker's list, a record write or a strip failed, after the rest ran (the
#     same call again is safe); 2 usage or config.

state_import() (
  [ $# -eq 2 ] || die "usage: state_import <plan|write> <strip|keep>" "$EXIT_USAGE"
  case "$1:$2" in plan:strip|plan:keep|write:strip|write:keep) ;; *) die "usage: state_import <plan|write> <strip|keep>" "$EXIT_USAGE" ;; esac
  flow_migrate_effect="$1"; flow_migrate_strip="$2"
  flow_migrate_tracker_state="$(tracker_state)" || exit "$EXIT_USAGE"
  [ "$flow_migrate_strip:$flow_migrate_tracker_state" != strip:labels ] \
    || die "import --strip under tracker_state labels: the mirror would write the state back; set tracker_state none first" "$EXIT_USAGE"
  flow_migrate_trackers="$(adapters_configured)" || exit "$EXIT_USAGE"
  flow_migrate_failed=0
  flow_migrate_lists="$(migrate_tracker_lists "$flow_migrate_trackers")" || flow_migrate_failed=1
  set --
  while IFS= read -r flow_migrate_entry; do
    [ -z "$flow_migrate_entry" ] || set -- "$@" "$flow_migrate_entry"
  done <<POOL
$(cfg pool)
POOL
  flow_migrate_rows="$(printf '%s\n' "$flow_migrate_lists" | cached_python3 -I "$FLOW_PLUGIN/scripts/_state.py" import \
    --state-dir "$(state_dir)" --flow-home "$(flow_home)" --now "$(now_iso)" --machine "$(flow_machine)" \
    --effect "$flow_migrate_effect" -- "$@")"
  case $? in 0) ;; 1) flow_migrate_failed=1 ;; *) exit "$EXIT_USAGE" ;; esac
  migrate_rows_done "$flow_migrate_effect" "$flow_migrate_strip" "$flow_migrate_rows" || flow_migrate_failed=1
  exit "$flow_migrate_failed"
)

migrate_tracker_lists() (
  flow_migrate_list_failed=0
  while IFS= read -r flow_migrate_tracker; do
    [ -n "$flow_migrate_tracker" ] || continue
    if flow_migrate_list="$( (adapter list "$flow_migrate_tracker") </dev/null)"; then
      printf '%s\n' "$flow_migrate_list" | tr -d '\n'; echo
    else
      echo "flow: import: the $flow_migrate_tracker list failed, so its items are not imported" >&2
      flow_migrate_list_failed=1
    fi
  done <<TRACKERS
$1
TRACKERS
  exit "$flow_migrate_list_failed"
)

migrate_rows_done() (
  flow_migrate_strip_failed=0
  flow_migrate_tab="$(printf '\t')"
  while IFS="$flow_migrate_tab" read -r flow_migrate_kind flow_migrate_item flow_migrate_detail; do
    case "$flow_migrate_kind" in
      import) migrate_import_row "$1" "$flow_migrate_item" "$flow_migrate_detail" ;;
      skip) migrate_report "$1" "skip $flow_migrate_item: $flow_migrate_detail" ;;
      strip) migrate_strip_row "$1" "$2" "$flow_migrate_item" || flow_migrate_strip_failed=1 ;;
    esac
  done <<ROWS
$(migrate_shaped_rows "$3")
ROWS
  exit "$flow_migrate_strip_failed"
)

migrate_shaped_rows() (
  flow_migrate_tab="$(printf '\t')"
  while IFS="$flow_migrate_tab" read -r flow_migrate_kind flow_migrate_item flow_migrate_detail; do
    if migrate_row_shaped "$flow_migrate_kind" "$flow_migrate_item" "$flow_migrate_detail"; then
      printf '%s\t%s\t%s\n' "$flow_migrate_kind" "$flow_migrate_item" "$flow_migrate_detail"
    elif [ -n "$flow_migrate_kind" ]; then
      echo "flow: import: a row that is no import, skip or strip of an item id is ignored" >&2
    fi
  done <<ROWS
$1
ROWS
)

migrate_row_shaped() {
  case "$1:$3" in import:held|import:unheld|skip:?*|strip:) item_id_shaped "$2" ;; *) return 1 ;; esac
}

migrate_import_row() (
  flow_migrate_held=""; [ "$3" != held ] || flow_migrate_held=", held by this machine"
  migrate_report "$1" "import $2$flow_migrate_held"
  [ "$1:$3" != write:held ] || ( tracker_take "$2" new ) </dev/null
)

migrate_strip_row() (
  [ "$2" != keep ] || { echo "$3 keeps its flow state on its tracker; state.sh import --strip takes it off"; exit 0; }
  [ "$1" != plan ] || { echo "would strip $3"; exit 0; }
  ( adapter strip-state "$3" ) </dev/null >/dev/null \
    || { echo "flow: import: $3: strip-state failed, so its tracker keeps its flow state" >&2; exit 1; }
  echo "strip $3"
)

migrate_report() {
  [ "$1" = write ] || printf 'would '
  printf '%s\n' "$2"
}
