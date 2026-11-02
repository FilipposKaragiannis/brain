bump: minor

- `flow:init` leaves no trace in tracking: its ignore block goes to the clone's `.git/info/exclude`
  and covers all of `.flow/`, which every linked worktree shares and nobody commits. `--check`
  reads the block there. The "Next" text no longer asks to commit `.flow/`.
- A repository that committed flow before migrates: init removes the `# flow:begin` block from
  `.gitignore` when every line in it is one init wrote (a block the owner added to is left and
  named), and prints `git rm -r --cached --quiet -- .flow` for the tracked files. It never runs it.
- The `.claude/settings.json` hook entry init prints runs the main worktree's `.flow/hooks`
  wrapper when the clone has one (from a linked worktree too), and otherwise makes the worktree
  as Claude does with no hook, so `claude --worktree` works for a teammate without flow. A
  WorktreeCreate hook that printed nothing would fail the session. `init --check` notes an entry
  an older init printed.
- The Codex rules and agents go to the user's `~/.codex` (`$CODEX_HOME`) with `init --user-codex`
  or when the repository has no `.codex/`, and to the repository's `.codex/` otherwise. A later run
  keeps the place the stamp records, and init says which on its `Codex rules and agents:` line.
- The session-start install check reads the stamp in the main worktree's `.flow`, so a session in
  a linked worktree, which has no `.flow/config.yaml` of its own now, is checked too.
