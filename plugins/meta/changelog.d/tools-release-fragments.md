bump: patch

- `retro`: a marketplace PR adds a changelog fragment per plugin it changes,
  `plugins/<plugin>/changelog.d/retro-<date>.md`, and never edits the version or `CHANGELOG.md`.
  The release PR folds the fragments (ADR 0002 in the marketplace).
