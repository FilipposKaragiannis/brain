# meta

## 1.1.5 (2026-11-08)

- `retro` reads the lessons whose time is after the last retro's time, not a line count, and
  writes the run's UTC time in the `retros.log` line. The log can be rewritten under it.

## 1.1.4 (2026-11-03)

- `retro` says the lessons log stays on this machine under `.flow/` and is never committed, as
  the flow's retro job no longer commits it.

## 1.1.3 (2026-11-01)

- `retro`: a marketplace PR adds a changelog fragment per plugin it changes,
  `plugins/<plugin>/changelog.d/retro-<date>.md`, and never edits the version or `CHANGELOG.md`.
  The release PR folds the fragments (ADR 0002 in the marketplace).
