bump: patch

- The installer uses the npm that came with the node it runs, not an older npm found first on the
  PATH (such as Homebrew's npm 6 beside an nvm node 24), which crashed in `npm ci`.
- An npm older than 7, which cannot read the app's lockfiles, now stops the install at the start
  with exit 2 and a message that names it and says what to install.
- `install` ends a failed install with the failing line and its one next step, nothing else.
- A failed install now always reads the same way, with nothing said twice: "The install
  failed.", the installer's line quoted exactly and cut before its advice, then `Next step:` with
  that advice. Before, the agent sometimes retold the line in its own words or repeated the
  line's advice as the next step, and `install-works` failed on those runs.
