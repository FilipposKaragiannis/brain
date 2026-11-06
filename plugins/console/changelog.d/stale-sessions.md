bump: minor

- Agents shows how each of your own sessions stands: "busy", "idle 3d 2h" from claude's
  `~/.claude/sessions/<pid>.json` (read only when its pid, folder and start are the process's), or
  its age for a Codex session or a claude with no such file. A session idle for
  `jobs.health.stale_session` (24h unset), or with no status running that long, is tagged stale;
  a busy one never is. Stale sessions come first, and the "Your sessions" fold opens by itself
  while any is stale, with the count in its heading. Running now on the overview says "N stale
  sessions: <worktrees>" with a link to Agents. The flow settings form gains the key.
- Stop session on each session row ends it with SIGTERM (`session.stop`, `kill -s TERM <pid>`,
  never SIGKILL), after a second press to confirm. It is refused unless the snapshot lists the pid
  as a session started when the page says, and just before the signal the daemon reads the pid
  again and stops nothing unless it still runs that claude or codex session, so a pid a later
  process took is never signalled. A stop starts on a full runner, like the other stops.
- The snapshot is schema 14: an agent gains `startedAt` and `activity` (`{status, since}` or null),
  and the project gains `staleSessionSeconds`.
- Settings shows `jobs.comments_workers` under Comments job: how many PRs one comments run
  addresses at once. Unset, 1.
- `claude mcp serve` is never listed as a session or an agent: Claude's MCP server serves
  another client from whatever folder it started in, as flow already reads it.
- Agents lists the Claude and Codex servers working in the project's worktrees in a read-only
  "Servers" fold after your sessions: the Claude daemon, Claude's MCP server, the Codex app server,
  its pid loop and its exec server, each with its pid, worktree and how long it has run, and its
  command on hover. They are never sessions, and the comments and health jobs ignore them; one
  working outside the project, such as the Codex app bundle's in your home folder, is not listed.
  The snapshot (still schema 14) gains `servers`.
