# _stale_pick_fixture.sh: stale_pick <ready list>, a next.sh --json pick from a ready list older
# than the tracker, for pick.sh and readiness.sh. It hands the list to next.sh the way next.sh
# hands its own list to the pick it starts again (the ready cache FLOW_NEXT_PID names): no other
# way makes a pick read a list from before an item changed, so this one place holds that knowledge
# of next.sh.
# Sourced, never run.
stale_pick() {
  sh -c 'mkdir -p .flow/tmp && printf "%s\n" "$2" > ".flow/tmp/.ready.$$"; FLOW_NEXT_PID=$$ exec "$1" --json' _ "$FLOW_PLUGIN/scripts/next.sh" "$1"
}
