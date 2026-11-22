bump: patch

- An item never moves past a human gate the tracker has not recorded. `advance.sh` writes the
  step after a gate and the gate itself in one tracker write (`gate.sh raise ... -- step=...`),
  on every path that raises one: the profile's gates, a gate the step asked for, the feel-test
  gate, the merge gate of an epic, a re-size and each escalation.
- A gate write the tracker refuses, or that dies, raises nothing: `advance.sh` exits 1 with the
  reason, the item keeps its step and its run, and `advance.sh` run again raises the gate once.
- A gate comment or notification that fails after the gate is recorded is said on stderr, and
  the gate stands. `notify.sh` says when the desktop notification fails.
- `next.sh` runs no step for an item with a gate record on this host that its tracker does not
  show; it exits 4 and names the record and how to answer it.
