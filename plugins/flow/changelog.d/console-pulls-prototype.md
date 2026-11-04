bump: minor

- The `comments` pass fixes the checks failing on a PR's head. A new Checks step, after
  Conflicts, spawns the `implementer` to read the failed logs, fix the cause in the task branch,
  build and test, then the `verifier`; on a pass it pushes (never force) and re-requests review.
  A failure that is not the change's (infra, a flake, a check red on the base too) gets no code
  change: the report says so, and an unattended pass stops on it.
- `comments.sh failing-checks <pr>` prints the checks failing on the PR's head, one name per
  line, sorted: the latest run of each check only, so a re-run that passed does not count, and a
  pending one waits. `comments.sh activity` carries them as `failing`.
- The comments job names the failing checks and the head in the brief ("Checks fail on
  <sha8>: A, B: run the Checks step."), drafts included. Its activity line ends in
  ` failing:<names>` only when a check fails, so a check gone red on the same head gets one pass,
  one the pass cannot fix is not tried again until the head changes, and a PR with no failing
  check keeps the line it had and gets no extra pass after the upgrade.
