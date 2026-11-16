# craft

## 1.0.1 (2026-11-16)

- improve writes its HTML report with the file-writing tool after resolving the path, not with a
  shell heredoc that breaks on the report's quotes and backticks.
- improve's chat reply ends its candidate list with a `**Top recommendation:**` line and stops
  there: no interface, signature or entry point for the deepened module until the owner picks.
- codebase-design says what a design answer must state: each dependency's category, the pure
  core that takes remote data as plain data, the two adapters that make a port a real seam, the
  small interface tests cross, and the rule ids.
