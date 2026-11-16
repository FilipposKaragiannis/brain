bump: patch

- implement, test, next and steward say what the comments skill says: a sandboxed Claude session
  commits and switches branches only in the worktree it started in. Run by hand from the main
  checkout, a step that commits, and next's or steward's claim of a pool worktree, fail on
  `index.lock`; the skill now names that in its report and stops instead of looking for a way
  around the sandbox. The unattended run already claims from a shell and starts each step in the
  item's worktree.
- The implementer, test-writer, comment-addresser and worktree-steward stop with that error on a
  commit, claim or release that fails on `index.lock`, and never work around it.
- The implement, test and next evals start their session in the item's pool worktree, with the
  main checkout inside it, as the comments eval does. implement and test pass only when a commit
  lands on the task branch and the result file says done; before, they passed on a failed step
  that never committed.
