bump: patch

- A gate's row in Needs you names its gate on the chip (`merge`, `escalation`, `plan-approval`
  …) instead of `gate`, so a narrow panel that clips the title still says which gate waits. The
  attention row carries the kind as `gate` (null on every other row); the snapshot is schema 9.
- Tests prove a project on the local tracker with `github.repo` set and no `trackers` gets what
  0.15.0's pulls read gave it: `pulls` reads ok, its open PRs list and link to the local item
  whose `pr` names them, the merge gate card carries a mergeable PR, a `pr-mergeable` row reaches
  Needs you, and the monitor sweeps a merge gate whose PR left the open list. Without
  `github.repo` the source still says it does not apply.
