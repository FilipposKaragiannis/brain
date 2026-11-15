# Agent notes

Project notes for agents.

## Testing the console

Test the console only on the demo project that `plugins/console/scripts/demo.sh` builds, never
on a real project. A trial console can make real changes in every project it watches, so never
point one at a real project, its worktrees or the owner's console settings.

- Run `plugins/console/scripts/demo.sh` from the repository root. It builds the demo in
  `$TMPDIR/brain-console-demo` and starts this checkout's console on it alone, on port 7478, in
  the foreground; Ctrl+C stops it. `--dir <folder>` and `--port <n>` move it.
- The demo has one item waiting at each gate (the feel-test one with the session that raised it),
  one ready item to run, a live run, a dead run, a session of yours, two job schedules with run
  history and a stopped host. Its agents are fake processes that end with the demo. Flow runs
  there call stub agents that spend no tokens; each call is a line in `agents.log` in the demo
  folder.
- The demo's home links your home, so a terminal it opens loads your shell setup, but never your
  `~/.claude`, `~/.codex`, console settings or launch agents. Its shell startup files then put the
  stub agents first on `PATH`, so a pane there runs no real agent.
- The token is in `<folder>/state/token`. Run the script again to reset the demo.
- Stop the demo console when you are done; leave no daemon running.
