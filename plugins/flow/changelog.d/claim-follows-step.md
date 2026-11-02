bump: patch

- The claim's step follows the issue's. `advance.sh` and `gate.sh` write each step change to the
  item's claim in the pool too (`step_write` in `lib/flow.sh`), so an item waiting at a gate or
  between runs no longer shows the step that last ran in its claim and the next step on the issue.
  That covers a step done, a failed step sent to its fix step, a re-size, a gate sent back, an item
  kept whole and a finished sync step. The console stops showing these as claim and issue
  disagreements, whose button would have moved the issue back a step.
