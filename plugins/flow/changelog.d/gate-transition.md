bump: patch

- An item never moves past a human gate the tracker has not recorded. `advance.sh` writes the
  step after a gate and the gate itself in one tracker write (`gate.sh raise ... -- step=...`),
  on every path that raises one: the profile's gates, a gate the step asked for, the feel-test
  gate, the merge gate of an epic, a re-size and each escalation.
- A gate write the tracker refuses, or that dies, raises nothing: `advance.sh` exits 1 with the
  reason, the item keeps its step and its run, and `advance.sh` run again raises the gate once.
  A write that fails after its labels landed (GitHub's state comment, Jira's state property)
  leaves the gate on the tracker, so `gate.sh` lets it stand, warns, and finishes the raise.
- `advance.sh` also exits 1, with its run kept, when the size or the next step cannot be written.
- A gate comment or notification that fails after the gate is recorded is said on stderr, and
  the gate stands. `notify.sh` says when the desktop notification fails.
- `next.sh` runs no step for an item with a gate record on this host that its tracker does not
  show; it exits 4 and names the record and how to answer it.
- What a retry can still double: the "Step ... done" comment and the plan's `held` line in
  `events.log`, which come before the write; and after a stop between the gate write and the
  run's removal, the gate comment, the notification and its `events.log` line. A comment cannot
  go in the same tracker write as the state, so one of them comes first and a retry repeats it.
  The state, the gate and its record stay one.
