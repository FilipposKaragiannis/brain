bump: minor

- A claimed pool worktree with no run, no agent and no gate no longer reads as work going on: it
  is `waiting` ("waiting for a worker · next <step>") or, when flow holds its item behind another,
  `held` ("held behind gh#X", linked, with the reason). Board, Overview and Worktrees say it the
  same way, the step reads as the next one, and a held claim is never flagged idle.
  A hold whose holder is closed reads as `waiting`: flow lets the item through and lifts the tag
  on its next run. The board lists open items only, so a closed holder is told by the board's
  `holders` read (flow's `board.sh --json`); one that could not be read keeps its hold.
- The snapshot carries `heldBy` and `heldReason` on items and worktrees from flow's `held_by` and
  `held_reason`, `counts.waiting`, `counts.held` and `readiness.held`; schema 15.
- Items to close (every step ran with no gate up, or every child of a split is closed) get their
  own Ready to close section on the Gates screen, each saying what to do, with the PR's merge
  button when it is ready. No flow gate is made up for them, and the Overview's needs-you count,
  the Gates heading and its nav badge now count the same items.
