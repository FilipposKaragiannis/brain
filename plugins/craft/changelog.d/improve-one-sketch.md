bump: patch

- improve's report opens with the candidates ranked, one line each, and the top recommendation,
  before any sketch. Each card holds a one-line verdict, one before and after sketch, the
  problem, the solution, the gain, the rules and the files, and an ADR conflict only when one
  is real.
- The sketch is a Mermaid flowchart, or a sequence diagram when round trips are the point; the
  report no longer mixes five diagram patterns. A sketch labels boxes with what the reader knows
  them as, keeps variable names out, stays near 20 arrows and says what it leaves out.
