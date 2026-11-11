bump: minor

- Terminal pane: a shell in a pty the daemon runs, rendered in the page, opened from the project
  bar (at the root) or from a worktree card or row (at that worktree). The panes sit in a dock at
  the bottom of the page, one tab each, and stay open across screens, projects and Settings; Close
  hangs the shell up, and a pane the daemon ended says why and keeps its screen.
- The daemon now has runtime dependencies, `@lydell/node-pty` and `ws`, both for the terminal pane
  (ADR 0003).
