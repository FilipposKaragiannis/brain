bump: patch

- Verify no longer passes against a comparison base that hides the item's committed work. A base
  that names the worktree's own branch, or that sits at HEAD while the branch holds commits the
  item's base lacks, is a failed `changed files` check saying the base is the item's own branch;
  this holds for `--base` too. When the base in the worktree's claim differs from the base the
  item's record holds, the check names both and verify picks neither. In both cases every check
  with paths runs, no kept test pass is reused and `feel_test` is true when `feel_test_paths` is
  set.
- With no valid base in the claim, verify compares with the base the item's record holds, and
  only then with the config base.
