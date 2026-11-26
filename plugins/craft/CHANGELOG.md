# craft

## 1.0.2 (2026-11-26)

- improve's report opens with the candidates ranked, one line each, and the top recommendation,
  before any sketch. Each card holds a one-line verdict, one before and after sketch, the
  problem, the solution, the gain, the rules and the files, and an ADR conflict only when one
  is real.
- The sketch is a Mermaid flowchart, or a sequence diagram when round trips are the point; the
  report no longer mixes five diagram patterns. A sketch labels boxes with what the reader knows
  them as, keeps variable names out, stays near 20 arrows and says what it leaves out.

## 1.0.1 (2026-11-16)

- improve writes its HTML report with the file-writing tool after resolving the path, not with a
  shell heredoc that breaks on the report's quotes and backticks.
- improve's chat reply ends its candidate list with a `**Top recommendation:**` line and stops
  there: no interface, signature or entry point for the deepened module until the owner picks.
- codebase-design says what a design answer must state: each dependency's category, the pure
  core that takes remote data as plain data, the two adapters that make a port a real seam, the
  small interface tests cross, and the rule ids.
