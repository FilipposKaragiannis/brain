# ADR 0004: the flow owns its state

Date: 2026-11-15. Status: accepted.

## Context
The flow kept an item's workflow state on its tracker (labels and a state comment, an issue
property or frontmatter; twenty keys through `write-state`) and in three local stores:
`claim.json`, `<flow home>/runs/` and `<flow home>/gates/` (ADR 0003). No store owned a fact, so
they could disagree, every issue carried flow vocabulary, and a step wrote under no lock.

## Decision
- One JSON record per item, `<state.dir>/<slug>.json` (default `<flow home>/state`), holds every
  workflow fact, the gate record of ADR 0003 included. `scripts/_state.py` is the only code that
  opens it; scripts go through `lib/state.sh` (`record_set <item> key=value...`, the twenty keys
  as before) and `scripts/state.sh`.
- Every record write is one process under a per-item `flock`: read, merge, temp file, rename.
  Readers take no lock.
- An adapter ends up reading and writing only what its tracker models: open, category, assignees,
  blockers, size, priority. Until the labels go, `record_set` sends each write to `write-state`
  first (`tracker_state: labels`, the default) and records it only when the tracker took it, and
  `runs/`, `gates/` and the claim's step are views `_state.py` writes when a write names their
  fact.
- Rejected: keeping `write-state` and routing it to a shared store (the adapter contract would
  still name an operation no tracker owns); a lock through `flow_lock` (one lock per process, and
  `next.sh` already holds `pick`); each script writing the record beside its old store (two
  writers per fact); recording first and only warning when the tracker refuses (the record and
  the labels people read would disagree).

## Consequences
- The record is per machine by default, as the gate record was: another machine sees an item's
  state only through the tracker's status and assignee, which later slices write natively.
- The record's schema (`v`) is a contract: the console reads the files.
- While the mirror is on, a tracker failure fails a flow write exactly as before.
- A worker in a sandbox cannot write `state.dir`: only orchestrator scripts write records, and a
  worker reports through its result file and `link-pr`.
