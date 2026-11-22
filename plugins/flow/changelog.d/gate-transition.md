bump: patch

- An item never moves past a human gate the tracker has not recorded. `advance.sh` writes the
  step after a gate and the gate itself in one tracker write (`gate.sh raise ... -- step=...`),
  on every path that raises one: the profile's gates, a gate the step asked for, the feel-test
  gate, the merge gate of an epic, a re-size and each escalation.
- A gate write the tracker refuses, or that dies, raises nothing: `advance.sh` exits 1 with the
  reason, the item keeps its step and its run, and `advance.sh` run again raises the gate once.
  A write that fails after its labels landed (GitHub's state comment, Jira's state property)
  leaves the gate on the tracker, so `gate.sh` lets it stand, warns, and finishes the raise.
- `advance.sh` also exits 1, with its run kept, when any state write a step ends with is refused:
  the touches, the plan's changes, its hold or the lift of one, a failed step's attempt, the next
  step, or the step done after a closeout or a pr step with nothing to merge. The retry applies the
  step as the first try would have.
- A re-size lands in the same tracker write as the step it moves to, so a refused write keeps the
  old size and profile and the retry re-sizes again; before, the retry kept the old profile.
- The run keeps the gate its step asked for, and the ask is recorded before the gate is raised, so
  neither a retry nor a stop after the raise asks the owner the same gate twice.
- `hold.sh set` exits 3 when the tracker does not take the hold, apart from 1 for a refused holder.
- A gate comment or notification that fails after the gate is recorded is said on stderr, and
  the gate stands. `notify.sh` says when the desktop notification fails.
- `next.sh` runs no step for an item with a gate record on this host that its tracker does not
  show; it exits 4 and names the record and how to answer it.
- What a retry can still double: the "Step ... done" and re-size comments and the plan's `held`
  line in `events.log`, which come before the write; and after a stop between a write and the
  run's removal, the gate comment, the notification and its `events.log` line, and a failed
  step's attempt. A comment cannot
  go in the same tracker write as the state, so one of them comes first and a retry repeats it.
  The state, the gate and its record stay one.
