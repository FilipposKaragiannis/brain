# Agent notes

Project notes for agents, and the allowed list that N-05 in `docs/coding-standards.md` refers to.

## Testing the console

Test the console only on the demo project that `plugins/console/scripts/demo.sh` builds, never
on a real project. A trial console can make real changes in every project it watches, so never
point one at a real project, its worktrees or the owner's console settings.

- Run `plugins/console/scripts/demo.sh` from the repository root. It builds the demo in
  `$TMPDIR/brain-console-demo` and starts this checkout's console on it alone, on port 7478, in
  the foreground; Ctrl+C stops it. `--dir <folder>` and `--port <n>` move it.
- The demo has one item waiting at each gate and one ready item to run. Flow runs there call stub
  agents that spend no tokens; each call is a line in `agents.log` in the demo folder.
- The token is in `<folder>/state/token`. Run the script again to reset the demo.
- Stop the demo console when you are done; leave no daemon running.

## Glossary

### Allowed abbreviations

- **pty**: pseudo-terminal; the node-pty library's term and the item's.
- **pid**: process id.
- **cols**: terminal columns; only at the wire and the node-pty boundary, daemon-owned names say
  `columns`.
- **cwd**: working folder; only at the node-pty and `child_process` boundary, daemon-owned names
  say `workingFolder`.
- **env**: environment variables; only at the node-pty boundary, daemon-owned names say
  `environment`.
