bump: minor

- The health job keeps an approved epic's branch up with its base: once the branch is more than
  `jobs.health.behind_base` commits behind, the base is merged in and pushed as a merge commit,
  with no worktree and never forced. A merge that conflicts changes nothing and is said and
  notified once per base and set of conflicted files; a refused push is said once and tried again
  on the next run. Merge a PR that carries such a merge with a merge commit, never a squash.
