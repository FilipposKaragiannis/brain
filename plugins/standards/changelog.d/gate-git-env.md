bump: patch

- A command gate runs without git's repository variables (`GIT_DIR`, `GIT_INDEX_FILE`,
  `GIT_WORK_TREE` and the rest of `git rev-parse --local-env-vars`). Git exports them to its
  hooks, so a gate that ran tests from the pre-commit hook aimed the tests' git at the repository
  being committed: a test's `git init --bare` made the main checkout bare and its `git config`
  wrote the test identity into it. The gate still runs from the repository root, where git finds
  the repository on its own. The hooks' own suite now runs in the repository's test sandbox.
