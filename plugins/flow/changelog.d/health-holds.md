bump: minor

- The health job sweeps the planned holds (`state.held_by`): a hold whose holder cannot be read or
  found, holds no worktree and has no run, or whose `changes` no longer share a path with the held
  item's is cleared, as is a hold on the item itself and the newest hold in a cycle. A hold whose
  holder closed stays, so `next` releases it with the note to merge and recheck the plan. Each clear
  is a line in the health result and an `unheld` line in `events.log`. A valid hold waiting over a
  day is said and notified once. Only the holders no tracker list holds are read, one read each.
- A `next` run with no item named works on after a gate: the item at the gate is set down and
  the run picks the next ready one, until `--max-steps` or nothing is ready, so a worker no
  longer sits idle until the next schedule. It ends as a gate (exit 4), and the job
  says it stopped at a gate with every step it ran. A named item still stops at its gate, and an
  escalation gate or a stopped host still ends any run.
