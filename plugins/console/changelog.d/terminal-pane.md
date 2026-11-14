bump: minor

- Terminal pane: a shell in a pty the daemon runs, rendered in the page, opened from the project
  bar (at the root) or from a worktree card or row (at that worktree). The panes sit in a dock at
  the bottom of the page, one tab each, and stay open across screens, projects and Settings; Close
  hangs the shell up, and a pane the daemon ended says why and keeps its screen. Drag the dock's
  top edge (or focus it and use the arrows) to resize it, and the terminal refits; the browser
  keeps the height. Scrolling over a pane never scrolls the page behind it, and the terminal uses
  an installed JetBrainsMono Nerd Font when there is one, so prompt icons draw.
- The daemon now has runtime dependencies, `@lydell/node-pty` and `ws`, both for the terminal pane
  (ADR 0003).
- Quick session: claude and Quick session: codex, beside each Terminal pane button, start that
  agent in the folder in a pane of its own, with the project's `jobs.<host>` model and effort (the
  deprecated `jobs.model` and `jobs.effort` while `jobs.<host>` is absent). The daemon runs the
  agent it finds on its `PATH`, with no permission flag, and refuses a model or an effort the host
  does not take, naming the key.
