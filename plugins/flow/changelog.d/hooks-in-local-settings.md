bump: minor

- `flow:init` writes the Claude `WorktreeCreate` and `WorktreeRemove` entries to this user's
  `.claude/settings.local.json` instead of printing them for the shared `.claude/settings.json`.
  It merges them into a file that exists (every other key and hook kept), creates the file and
  `.claude/` when missing, refuses a file that is not JSON, and adds the file to the exclude block.
  `init --check` reports a missing or changed entry there as drift.
- The entries only run the main worktree's `.flow/hooks/worktree-*.sh`. The fallback that made a
  worktree as Claude does when flow was absent is gone: a teammate without flow has no entry, and
  Claude makes its own worktree.
- When the committed `.claude/settings.json` still carries a flow hook entry, init's "Next" list
  and `--check` say to remove it and print it. Init never edits that file. Owner action: remove
  the entry from `.claude/settings.json`, commit that, and run `flow:init` once.
