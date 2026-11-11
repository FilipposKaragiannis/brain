# ADR 0003: the console daemon takes runtime dependencies for the terminal pane

Date: 2026-11-10. Status: accepted.

## Context
The console daemon ran on Node alone: `plugins/console/app/README.md` said "no runtime
dependencies", so `npm ci` fetched only dev tools. A terminal pane needs a pty the page can resize.
Node has none; `script(1)` cannot set the inner window size; a python3 helper needs a python3 a
stock Mac lacks.

## Decision
- The daemon takes two runtime dependencies: node-pty, loaded only by `daemon/src/pty.ts` and
  only when the first pane opens, and `ws`, loaded only by `daemon/src/paneSocket.ts`.
- node-pty comes as `@lydell/node-pty`, a prebuilt distribution of it with the same API. Upstream
  `node-pty` 1.1.0 ships its macOS `spawn-helper` without the execute bit, so every spawn fails
  with `posix_spawnp failed`, and it has no Linux prebuild. Swapping back is `pty.ts` and the
  lockfile.
- The README line now names them. Any further runtime dependency of the daemon needs its own ADR.
- Rejected: a python3 or `script` helper (no resize, or no python3); a hand-written WebSocket
  server (protocol code that is easy to get subtly wrong); SSE plus POST (two channels and input
  ordering to own).

## Consequences
- `npm ci` runs no install script for the pty: npm installs the one prebuilt package for the
  platform (macOS and Linux, arm64 and x64), so nothing compiles, in CI or on the owner's Mac.
  `npm ci --omit=optional` would leave it out.
- A pty addon that cannot load refuses panes with the reason; the daemon still starts.
- The token now opens a shell as the owner, not only the console's fixed actions.
