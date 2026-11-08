bump: minor

- The agents page shows every working agent, claude or codex, headless included. Each run card
  says its host, item, step or flow job, worktree, that it is headless, when its process started
  and how long it has run, and, while folded, its latest transcript line.
- A `codex exec -C <dir>` run started from the project root, as flow starts a Codex run, is listed
  under the worktree `<dir>` names and finds its Codex session there. Only codex's options before
  its prompt count, so a `-C` the prompt mentions does not.
- An agent carries `step` and `job` beside `item` (snapshot schema 16). `job` is the flow job it
  runs under, found by walking its parents in the one ps read: a comments, health, intake or retro
  run at the project root is named instead of anonymous. `item` falls back from the claim to the
  run the agent works for, and `step` comes from that run when it is of the same item.
- The transcript route reads Codex sessions too: messages, reasoning summaries, shell commands
  with their script, tool calls, and an `error:` line after one that failed. A folded card's one
  line reads a 64 KB tail, not 4 MB; the read still doubles while it holds too few lines.
