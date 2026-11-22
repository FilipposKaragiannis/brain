bump: patch

- A Claude step waits up to an hour for the background subagents its session left running
  (`CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`; a value the owner exported wins). At the host's own
  10 minutes, a review's Unity reviewer was stopped mid-run and the step wrote no result.
- A step whose session left no result file runs again, not its fix step. The runner writes that
  result with status `lost`. A lost review used to go back to implement, which had nothing to
  do, and the steps after it reset the attempt count, so the loop never reached the escalation
  gate. Run `/flow:init` to install the new `run-unattended.sh`.
- The implementer, sent back for a rule breach, fixes every instance of it in the branch diff,
  not only the line the review cites.
- The test writer's helpers, fakes and rigs meet the hard rules as production code does: a name
  that says every write (M-08), wrapped non-private parameters (S-05), named literals (N-06), and
  no production member added to reset state.
