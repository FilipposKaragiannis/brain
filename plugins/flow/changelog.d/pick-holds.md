bump: minor

- `next.sh` no longer skips a ready item whose `touches` overlap a running item's: the check ran
  only against in-flight runs and only for items that had recorded touches, so it kept nothing
  apart and cost parallelism. The plan step's hold (`state.held_by`) replaces it.
- A held item is not ready past its plan: `filter-ready` holds back an item whose `held_by` names
  an item that is still open, read through its adapter as a blocker is. A holder closed or not
  found holds nothing. A named held item exits 4 with `<item> is held behind <holder>: <reason>`;
  a pick passes it over. The plan and the steps before it still run, so a held plan sent back at
  its gate is planned again, and the brief says that plan decides the hold anew.
- Once a claim in a pick finds the pool full, the pick skips every ready item that holds no claim
  and whose step needs a worktree with no tracker read and no claim attempt, and tries the claimed
  ones. One pass with a full pool no longer holds the pick lock long enough for the other workers
  to give up.
- A pick that finds nothing says why on its last line, and the next job's quiet line carries it:
  `no free worktree for the N unclaimed ready item(s), and the pool is at pool_max; the claimed
  items: 2 running, 3 held (gh#1 behind gh#2, ...)`, or `nothing ready: 1 running, 2 blocked`.
  A named held item is a quiet run that names its holder, not a gate.
- `board.sh --json` carries `holders`: the status (`open`, `closed` or `unknown`) of each holder
  an open item is held behind that the open-item list leaves out, read once each.
