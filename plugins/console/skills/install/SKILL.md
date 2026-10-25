---
name: install
description: Put the Brain Console on this machine and start it on login.
disable-model-invocation: true
---

Install the Brain Console from this plugin: the app under `~/.local/share/brain-console/`, the
`brain-console` command in `~/.local/bin`, and the launch agent that starts it on login.

## Steps

1. **Pick the projects.** The console watches folders that hold `.flow/config.yaml`. Take the
   folders the owner named. When they named none and the current repository's root has
   `.flow/config.yaml`, take that root. Done when you have the list, empty or not.
2. **Run the installer**, with `--project <folder>` for each folder from step 1:
   ```
   "<plugin root>/scripts/install.sh" --project <folder>
   ```
   The plugin root is two folders up from this skill (`${CLAUDE_PLUGIN_ROOT}` on Claude; on
   Codex, the path `codex plugin list` prints for `console`). Add `--no-launchd` only when the owner asked not to start it on login. It takes a
   minute: it copies the app, runs `npm ci` and builds the page. Done when it exits.
3. **Handle the exit code.** 2: node or npm is missing or too old; say what to install, in the
   installer's words, and stop. 1 with "no projects": the files are in place; ask which folder to
   watch, then run `brain-console add <folder>` and `brain-console install`. Any other 1: show the
   failing line and stop. Done when the install succeeded or the owner knows the one next step.
4. **Report once**, in a few lines: the version installed, whether it runs under launchd and on
   which URL (from the `status` lines at the end, never the token), the PATH line to add when the
   installer printed one, and `brain-console open` to see it. Done when the message ends on that
   command.

## Never

- Never edit the owner's shell profile or run anything with sudo; print the line for them to add.
