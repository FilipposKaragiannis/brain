bump: minor

- The Pull requests screen follows the prototype. Each card's head names its branch and base and
  links Open on GitHub; six health cells (state, checks, conflicts, review, threads, quiz); a
  "Checks on <head>" list with each failed or running check linked to its run and the passed ones
  folded; the reviewers; a "Today" timeline of the flow's events on the PR's item; Merge now,
  disabled with the reason while the PR is not ready.
- Merge when green arms GitHub's auto-merge (`pr.auto-merge`, `gh pr merge --auto --squash`), and
  Disarm takes it back (`--disable-auto`); an armed card says so.
- Ask the agent to fix the checks, on a PR whose checks fail, runs the comments pass on its item
  and PR now; the pass's new Checks step fixes them.
- The head line counts the PRs merged today and offers Run comments job now; a Merged today list
  under the cards shows each with its item, time, how long it was open and its branch.
- The `pulls` source reads each check's latest run, the head commit, the auto-merge and the PRs
  merged since local midnight. The snapshot is schema 13: `PullRequest` gains `checkRuns`, `head`
  and `autoMerge`, and the snapshot gains `mergedToday`.
