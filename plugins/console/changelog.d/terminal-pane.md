bump: minor

- Terminal pane: a shell in a pty the daemon runs, rendered in the page, opened from the project
  bar (at the root) or from a worktree card or row (at that worktree). The panes sit in a dock at
  the bottom of the page, one tab each, and stay open across screens, projects and Settings; Close
  hangs the shell up and kills what it left running 1.5 s later, and a pane the daemon ended says
  why and keeps its screen. Drag the dock's top edge (or focus it and use the arrows) to resize
  it, and the terminal refits; the browser keeps the height. Scrolling over a pane never scrolls
  the page behind it, and the terminal uses an installed JetBrainsMono Nerd Font when there is
  one, so prompt icons draw.
- The pane replaces the outside terminal app: Open in Terminal on the project bar, a worktree, a
  dead run or a process with no session opens a shell pane (one button where there were two);
  Follow log on a job opens a pane that follows its log, and waits for it when the job has not
  run yet; Open session and Discuss with the agent open a pane that resumes the session, showing
  the resume command instead while the run still goes. The tabs say which: `shell · <folder>`,
  `log · <job>` or `session · <folder or item>`. The `terminal.open` action is gone.
- Settings no longer has a Terminal choice, and the `terminal` setting is gone: a settings file
  that still holds it loads as before, and the next save leaves it out. `PUT /api/settings` now
  refuses a `terminal` key as an unknown setting.
- The daemon now has runtime dependencies, `@lydell/node-pty` and `ws`, both for the terminal pane
  (ADR 0003).
