bump: patch

- init words each config question the same way: the value it wrote ("written `3`", "written
  empty") and a value it recommends, never only advice. With no reviewer that can answer on the
  repository, it recommends `reviews.reviewers: []`.
- implement's report names the task branch and the worktree, also when the step fails or stops
  at a gate, so the owner knows where uncommitted work sits.
