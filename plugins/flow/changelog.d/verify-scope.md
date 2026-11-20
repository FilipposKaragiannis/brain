bump: minor

- Verify runs only the build and test commands a change can affect. `build` and `test` in
  `.standards/config.json` take a map `{command, paths}`, and `test` a list of
  `{name, command, paths}`, one check `tests <name>` each. A command with paths runs when a file
  changed since the base matches a glob, else it is a skipped check that says why. A moved file
  counts at its old path and its new one. A command with no paths always runs, and a config
  written before behaves as before.
- Verify does not run a test command again that passed on the same command and the same files. The
  check is a pass that names the run it came from. A command with no paths is reused only while
  the whole tree is unchanged, a failed one never (a failed run drops the pass kept for its
  inputs), and one with an uncommitted change under its paths always runs.
  `verify.sh <item> --fresh` runs every command. The passes are kept in `.flow/checks` of the main
  worktree, shared by its worktrees, never committed. A build always runs: its outputs are ignored
  files, which a pass kept in another worktree cannot bring back.
- Every check in `verify.json` carries its `seconds`, the report the run's total, and `verify.md`
  shows the time beside each check.
- A verify run that was stopped at `verify.limit`, by a signal or by a kill failed no check: its
  report says `stopped`, and the item stays at verify behind the escalation gate with no attempt
  counted. It went back to implement before, where there was nothing to fix. A run stopped after
  a check failed names that check and goes back to implement, as a failed run does.
- The implementer, the test writer and the comment addresser run only the tests they touched,
  alone, and never the project's whole test command: verify runs it once. A plan phase's
  verification names the tests that cover the phase. No agent stops a process it did not start
  or one by its name, which ended other worktrees' runs.
- An epic's step that names a size no longer raises the re-size gate. An epic has no size, so
  the gate came back each time it was cleared.
- A build or test entry that cannot be read is a failed `config` check that names the entry.
