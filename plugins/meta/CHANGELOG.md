# meta

## 1.1.4 (2026-11-03)

- `retro` says the lessons log stays on this machine under `.flow/` and is never committed, as
  the flow's retro job no longer commits it.

## 1.1.3 (2026-11-01)

- `retro`: a marketplace PR adds a changelog fragment per plugin it changes,
  `plugins/<plugin>/changelog.d/retro-<date>.md`, and never edits the version or `CHANGELOG.md`.
  The release PR folds the fragments (ADR 0002 in the marketplace).
