bump: minor

- A red check never ends a `comments` pass. The Checks step fixes what is the change's; a failure
  that is not (infra, billing, a flake, a check red on the base too) gets no code change, the report
  says so, and the pass goes on to the threads. Since 1.32.0 an unattended pass stopped there, left
  each thread "for the next pass", and the job gave up on the thread after its one extra pass: with
  CI blocked, no review thread was answered. A fix the verifier rejects goes to a local
  `<branch>-rejected-<sha>` branch and the task branch goes back to its head, so a thread's push
  never publishes it. The job's brief says to run the Checks step, then the threads whatever it
  finds, and to address every thread before it ends.
- The comments job's result line names every open PR and what it came to, instead of counting
  "nothing new" for PRs it had given up on: `quiet: nothing new on 1 PR(s): gh#695; 2 wait on you:
  gh#523 (thread(s) 4470724616 unanswered after two passes), gh#626 (…); 1 in use: gh#416 (claude
  process 62102, idle 3d 2h in app-wt-10); at a gate: gh#7 (ambiguity gate)`. A PR the job stopped
  trying after failed passes waits on you too, with the count.
- The Codex desktop app's servers no longer count as a session in a worktree. `codex app-server`,
  its `app-server daemon` and `exec-server` keep the folder they were started in for days, and the
  comments job skipped that worktree's PR the whole time. Only the subcommand names a server, and
  never in an unattended run, so `claude -p mcp is broken` stays a run. The health scan reads the
  first two words after the executable that are not options, as the console does.
- A Claude desktop session counts as a session in its worktree. The app keeps its CLI under
  `~/Library/Application Support/Claude/`, and ps prints that path unquoted, so the health scan read
  only up to the space and never saw the session. It rejoins such a path as the console does.
- A skipped PR's session is named with how long it has been idle (`claude process 62102, idle 3d
  2h`), from the status Claude keeps in `~/.claude/sessions/<pid>.json`; a host with no status shows
  how long it has run. The owner's notice ends in the kill command.
- `steward.sh sessions [--stale]` lists the claude and codex sessions in the main worktree and the
  pool: pid, host, kind, worktree, the item its claim holds, busy or idle and for how long. One idle
  past `jobs.health.stale_session` (default 24h; with no status, alive that long) is marked STALE
  with its `kill <pid>`. The `health` job names each stale session once while it stays, with what it
  holds back.
- `flow:init` writes `jobs.comments_workers` and `jobs.health.stale_session` into the config it
  makes, commented, so both settings can be found.
