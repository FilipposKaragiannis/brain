# ADR 0005: tracker state is the mirror only

Date: 2026-11-26. Status: accepted.

## Context
1b made the tracker read of an item with no flow record follow `tracker_state`: under `labels` it
read the tracker's state, under `none` an empty one (ADR 0004). That was right while `none` was a
test lane no release defaulted to. Slices 1a to 3 ship with the flip of the default to `none`, so
at the upgrade every item in flight is unrecorded: under the 1b rule each would read as unstarted,
`next.sh` would start it again from its first step, `advance.sh` would find no run and
`gate.sh list` no gate.

## Decision
- `tracker_state` switches the mirror only: under `none` (the default) no record write reaches the
  tracker, under `labels` every one does, as before.
- An item with no record reads and seeds from its tracker in both modes until 4b: its state is the
  tracker's, its run and gate files list as its rows, and its first write copies that state, but
  `size`, into a record (the lazy seed). `state.sh import` runs the same seed over every open item
  at once, and `--strip` then takes the state off the trackers of the items recorded on this
  machine.
- Only orchestrator scripts call `link-pr`, through `link_and_record_pull_request`, and it writes no
  state: the record takes `pr` and `pr_host`. A worker reports its PR in its result file.
- Rejected: keeping the 1b rule and requiring `state.sh import` after the upgrade (unattended loops
  and the health job run before any person does, and restart every item in flight); importing in
  `next.sh` only (one entry point of five); the worker still calling `link-pr` (with no `pr` on the
  tracker nothing tells whether it ran).

## Consequences
- Work in flight carries over with no command, at the cost of reading labels that are frozen once
  the mirror stops: a record wins once it exists, and health and `state.sh import --strip` remove
  the labels.
- A team keeps `tracker_state: labels` until every machine runs this release, then imports on each,
  then strips: two machines can both seed a started item that has no worktree.
- 4b removes the tracker read, the seed, `write-state` and `strip-state`.
