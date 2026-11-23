bump: patch

- Verify no longer passes against a comparison base that hides the item's committed work. A base
  that names the worktree's branch or the task branch the item's record holds, unless it is the
  base the record holds or the config base, or that sits at HEAD while the branch holds commits
  the item's base lacks, is a failed `changed files` check saying the base is the item's own
  branch; this holds for `--base` too. When the base in the worktree's claim differs from the base
  the item's record holds, the check names both and verify picks neither: the report has no base
  and `{verify_base}` is `unavailable`. In each case the check reads "verify cannot trust the
  comparison, so it cannot pass", every check with paths runs, no kept test pass is reused and
  `feel_test` is true when `feel_test_paths` is set.
- Verify fails closed when it cannot read HEAD's commit or the branch HEAD is on: the
  `changed files` check says "verify cannot read HEAD".
- Verify reads the branch HEAD is on by its full ref, so a tag named like the task branch no
  longer hides that the base is the item's own branch.
- When the item's record holds a task branch that exists, verify refuses a HEAD that is not at
  that branch's commit: the `changed files` check says "HEAD is not the item's branch" and names
  it.
- Verify reads the base by its full branch ref, so a tag named like the base (`main` or
  `origin/main`) no longer stands in for it.
- With no valid base in the claim, verify compares with the base the item's record holds, and
  only then with the config base. An item whose record holds no base has only its claim to go by.
- A pr step that ends with no pull request compares the branch with the base the item's record
  holds, else the claim's. A base that is the task branch itself escalates instead of closing the
  item as having nothing to merge.
- A release reads the claim's base by its full ref, the remote's when origin has one, and keeps
  the task branch when that base is the branch itself, is no valid name or does not resolve, so a
  claim base such as `heads/<task branch>` no longer deletes the branch it names.
