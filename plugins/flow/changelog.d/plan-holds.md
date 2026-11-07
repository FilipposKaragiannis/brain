bump: minor

- The plan step decides holds. Two items conflict only when both change existing behavior in
  the same code and the clash would be hard to resolve; additive work, docs and tests never do,
  and a small overlap in doubt runs in parallel. The rule lives in `skills/plan/holds.md`.
- `scripts/hold.sh candidates <item>` lists the other open items holding a claim whose `changes`
  (or `touches`, lacking changes) share a path prefix with the item's touches, with each one's
  plan report. The plan brief gets an `## Other open work` section only when it lists something;
  the planner checks its final touches with `--touches` before it reports.
- The plan result carries `changes` (the globs among `touches` whose existing behavior the plan
  changes) and, for a conflict, `hold: {behind, reason}`. `advance.sh` writes `changes`, and
  with a hold `held_by`, `held_reason` and a `held` line in `events.log`; the gate and the
  comment say it. A replan with no hold lifts an earlier one (`unheld`).
- `next.sh` lifts a hold once its holder has closed (`unheld` line) and the brief tells the agent
  to merge the base in first, never rebase, and to stop at an ambiguity gate when the plan no
  longer fits.
- A verify run starts on merged code: `next.sh` merges the base into a clean task branch that is
  behind it before the verify step (an `events.log` `sync` line); a merge that conflicts is
  aborted and runs as the sync step first.
- The explorer's design result carries `touches`, so the plan brief can judge other open work
  before the plan exists.
