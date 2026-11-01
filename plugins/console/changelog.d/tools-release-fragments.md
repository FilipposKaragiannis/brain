bump: patch

- The app's `package.json` and `package-lock.json` (daemon and UI) carry the plugin's version,
  0.11.0 here instead of 0.8.0 and 0.7.2. The hosts cache the plugin by that version, so the
  installed console no longer looks older than the cached one. `tools/release.sh` now stamps it
  on every release and `tools/lint.sh` fails when they differ.
