bump: minor

- An epic's closeout ends in the epic's pull request. When the closeout passes and the epic
  branch holds commits its base lacks, the flow opens a GitHub PR from `epic/<n>` into the branch
  the epic started from (an epic branch above it, a `base:` line in its body, else the config
  base), records it on the epic and raises the merge gate (`scripts/epic-pr.sh`). An open PR from
  that branch is taken as it is. The epic stays open until the merge.
- The sweep closes an item that waits at the merge gate with no claim once its PR is merged: an
  epic holds no worktree, so the claimed-worktree sweep never saw it.
- With no epic branch, or nothing on it to merge, the flow closes the epic after the closeout. The
  verifier no longer closes an epic or opens its PR; it reports the closeout's result.
- A PR that gh cannot open leaves the epic open at closeout behind an escalation gate that names
  the `gh pr create` command. Clearing it runs the closeout again, which takes the PR the owner
  opened.
