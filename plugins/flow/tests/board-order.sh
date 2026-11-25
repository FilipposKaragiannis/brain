#!/bin/sh
# board-order.sh: the sections board.sh prints, on the local adapter in throwaway repos. What waits
# on the owner leads, even ahead of the health notes and when nothing waits; the pool follows the
# running and ready items; an empty section prints at most its heading line, never a table
# heading with no row under it.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

LONG_AGO="2026-01-01T00:00:00Z"
# end_run_long_ago <item>: points the item's run record at a process that has ended and dates it
# long ago, as a run whose session died leaves it.
end_run_long_ago() {
  sh -c 'exit 0' & ended_pid=$!; wait "$ended_pid"
  python3 -c 'import json,sys; path=sys.argv[1]; record=json.load(open(path)); record["pid"]=int(sys.argv[2]); record["started"]=sys.argv[3]; json.dump(record,open(path,"w"))' \
    "$(run_file "$1")" "$ended_pid" "$LONG_AGO"
}
first_heading() { grep -m 1 '^## ' "$1"; }

echo "board order: what waits on you leads, the pool follows the items"
new_repo busy
ready="$(new_task "Ready to start")"
gated="$(new_task "Asks the owner")"
running="$(new_task "Runs now")"
"$local_adapter/write-state.sh" "$gated" step=implement profile=task-S >/dev/null
start_step "$gated"
step_result "$gated" implement '{"status":"gate","gate":"ambiguity","message":"**A or B?**"}'
finish_step "$gated"
start_step "$running"
end_run_long_ago "$running"
"$plugin/scripts/board.sh" > "$work/busy.board" 2>/dev/null
check "ItemAtAGateWithADeadRun_WaitingOnYouIsTheFirstSection: the first heading is Waiting on you, ahead of Health, because the owner opens the board to see what needs them" \
  '[ "$(first_heading "$work/busy.board")" = "## Waiting on you" ]'
check "RunningAndReadyItems_PoolComesAfterBoth: the Pool heading follows the rows of the running and the ready item, because the owner acts on items before worktrees" \
  '[ "$(awk -v ready="| $ready |" -v running="| $running |" "index(\$0, ready) == 1 { seen_ready = 1 } index(\$0, running) == 1 { seen_running = 1 } /^## Pool/ { print (seen_ready && seen_running) ? \"after\" : \"before\"; exit }" "$work/busy.board")" = after ]'

echo "board order: an empty board"
new_repo quiet
printf 'adapters:\n  default: local\nbase: main\npool:\npool_max: 8\nnotify:\n  desktop: false\n' > .flow/config.yaml
"$plugin/scripts/board.sh" > "$work/quiet.board" 2>/dev/null
check "NothingAtAnyGate_WaitingOnYouStillLeads: the first heading is the Waiting on you one, because the owner looks there first whether or not anything waits" \
  'first_heading "$work/quiet.board" | grep -q "^## Waiting on you"'
check "NothingAtAnyGate_WaitingOnYouIsOneLine: the line after the Waiting on you heading is blank, because an empty section prints its heading line alone" \
  '[ -z "$(sed -n 2p "$work/quiet.board")" ]'
check "NoItemsAndNoWorktrees_NoTableHeadingStandsAlone: every table separator is followed by a row, because an empty section prints one line or nothing, never a bare table heading" \
  '[ -z "$(awk "previous_was_separator && index(\$0, \"| \") != 1 { print NR } { previous_was_separator = (index(\$0, \"|---\") == 1) } END { if (previous_was_separator) print \"end\" }" "$work/quiet.board")" ]'

if [ "$fails" -eq 0 ]; then echo "board-order: ok"; else echo "board-order: $fails failed"; exit 1; fi
