# Holds: when a plan waits behind other open work

The plan step decides whether this item waits for another open item to close before it is
implemented. Only the item planned later is checked, so each pair is judged once. The brief's
`## Other open work` section, or `scripts/hold.sh candidates <item> --touches <globs>`, lists
the open items that hold a claim and change code your touches reach. Nothing listed: no hold.

## The rule

Two items conflict only when both change existing logic or behavior in the same code, and
resolving the clash would be hard.

- Additive changes never conflict: new files, new tests, new doc rows, new methods or cases
  that leave the existing code's behavior alone.
- Docs and tests are never grounds for a hold.
- Judge by behavior, not by whether lines were added or edited: a new enum value or switch case
  that changes what old code does is a change.
- In doubt, with a small overlap, run in parallel. The merge of the base into the branch before
  verify, and verify itself, are the safety net.

Read the other item's plan report when the list names one, to see what it changes.

## What to report

In the result file, `changes`: the globs among your `touches` whose existing behavior your plan
changes (additive work is left out; empty when the plan only adds). With a conflict, also
`"hold": {"behind": "<the other item's id>", "reason": "<one line: the code both change and why
merging would be hard>"}`. One hold at most, behind the item whose clash is the hardest. No
conflict: no `hold` key. The flow writes the hold and keeps the steps after the plan back until
that item closes; the run after it merges the base in and checks the plan still fits. A plan sent
back at its gate runs again while the item is held, and decides anew: report the `hold` to keep
it, leave it out and the hold is lifted.
