# Agent notes

Project notes for agents, and the allowed list that N-05 in `docs/coding-standards.md` refers to.

## Glossary

### Allowed abbreviations

- **pty**: pseudo-terminal; the node-pty library's term and the item's.
- **pid**: process id.
- **cols**: terminal columns; only at the wire and the node-pty boundary, daemon-owned names say
  `columns`.
- **cwd**: working folder; only at the node-pty and `child_process` boundary, daemon-owned names
  say `workingFolder`.
