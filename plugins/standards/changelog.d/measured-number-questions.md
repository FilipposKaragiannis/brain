bump: patch

- The performance reviewer puts a fixed list of questions to every measured number a diff, a
  commit message or the PR body claims: what was measured, on what machine and build, how many
  runs, the spread, the baseline, what was left out and how to run it again. It reports which
  ones the PR answers; an unanswered one is a P2 comment under P-01, never a blocker. With no
  number claimed it asks none of them.
- The review spawns the performance reviewer when a number is claimed, even outside a hot path.
