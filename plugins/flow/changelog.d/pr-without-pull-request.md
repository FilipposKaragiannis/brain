bump: patch

- A pr step that ends `done` with no PR no longer leaves the item at a merge gate nothing clears.
  `advance.sh` looks for a PR on the task branch, as the sweep does, and records one it finds
  before the merge gate. With none and nothing to merge (a clean tree and no diff against the
  claim's base) it closes the item with the step's summary, says why in the closing comment and
  releases the worktree. With none and changes on the branch it raises an escalation gate. A
  tracker that refuses the close raises an escalation gate too.
- `board` lists a merge gate whose item has no PR linked under Health, not under "Waiting on
  you", and leaves it out of the gate reminder.
- The pr skill and `pr-creator` define the result with no PR: `done` with no `pr` key, only when
  the branch has nothing to merge.
