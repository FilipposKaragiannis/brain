bump: patch

- Verify no longer passes against a comparison base that hides the item's committed work. A base
  that names the worktree's branch or the task branch the item's record holds, or that sits at
  HEAD while the branch holds commits the item's base lacks, is a failed `changed files` check
  saying the base is the item's own branch; this holds for `--base` too. When the base in the
  worktree's claim differs from the base the item's record holds, the check names both and verify
  picks neither: the report has no base and `{verify_base}` is `unavailable`. In each case every
  check with paths runs, no kept test pass is reused and `feel_test` is true when
  `feel_test_paths` is set.
- Verify reads the base by its full branch ref, so a tag named like the base (`main` or
  `origin/main`) no longer stands in for it.
- With no valid base in the claim, verify compares with the base the item's record holds, and
  only then with the config base.
- A pr step that ends with no pull request compares the branch with the base the item's record
  holds, so a claim base rewritten to the task branch escalates instead of closing the item as
  having nothing to merge, and a release never deletes a task branch whose claim names it as its
  base.
