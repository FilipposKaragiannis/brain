#!/bin/sh
# Carries the flow state an older flow left on the trackers into the flow records, and takes it
# off them. Sourced by scripts/state.sh only, after lib/flow.sh; defines functions and runs nothing.
# Neither function changes a variable of its caller or reads its stdin.
#   state_import <plan|write> <strip|keep>
#                               lists every configured tracker (adapters_configured) and says one
#                               line per row scripts/_state_import.py gives: each open item whose
#                               tracker state carries flow state and that has no record is
#                               imported (its record seeded as the lazy seed does) or skipped when
#                               its worktree is not claimed on this machine. Under write a held
#                               import is assigned and its status pushed (tracker_take new); with
#                               strip, adapter strip-state then cleans each item recorded here that
#                               still carries flow state or labels, and without it each is named.
#                               plan says what write would do, with "would", and changes nothing.
#                               strip is refused, exit 2, under tracker_state labels, whose mirror
#                               would write the state back. Exit 0 done; 1 a tracker's list, a
#                               record write or a strip failed, after the rest ran (the same call
#                               again is safe); 2 usage or config

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
  flow_migrate_would=""; [ "$1" = write ] || flow_migrate_would="would "
  flow_migrate_strip_failed=0
  flow_migrate_tab="$(printf '\t')"
  while IFS="$flow_migrate_tab" read -r flow_migrate_kind flow_migrate_item flow_migrate_detail; do
    case "$flow_migrate_kind" in
      import)
        flow_migrate_held=""; [ "$flow_migrate_detail" != held ] || flow_migrate_held=", held by this machine"
        echo "${flow_migrate_would}import $flow_migrate_item$flow_migrate_held"
        [ "$1:$flow_migrate_detail" != write:held ] || ( tracker_take "$flow_migrate_item" new ) </dev/null ;;
      skip) echo "${flow_migrate_would}skip $flow_migrate_item: $flow_migrate_detail" ;;
      strip)
        if [ "$2" = keep ]; then
          echo "$flow_migrate_item keeps its flow state on its tracker; state.sh import --strip takes it off"
        elif [ "$1" = plan ]; then
          echo "would strip $flow_migrate_item"
        elif ( adapter strip-state "$flow_migrate_item" ) </dev/null >/dev/null; then
          echo "strip $flow_migrate_item"
        else
          echo "flow: import: $flow_migrate_item: strip-state failed, so its tracker keeps its flow state" >&2
          flow_migrate_strip_failed=1
        fi ;;
    esac
  done <<ROWS
$3
ROWS
  exit "$flow_migrate_strip_failed"
)
