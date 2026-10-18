---
type: regex
pattern: "^#{1,4}[ \\t]*(?:\\*\\*)?Standards\\b[\\s\\S]*?\\b(?:D-09|D-10|N-06|C-01)\\b[\\s\\S]*?^#{1,4}[ \\t]*(?:\\*\\*)?Spec\\b"
flags: "m"
match: contains
target: last_message
---
The review cites at least one of the rules the snippet breaks (D-09 optional parameter, D-10
static mutable state, N-06 magic number, C-01 comment explaining code) under its own Standards
heading, with the Spec axis reported apart after it. The fixture's AGENTS.md block lists these ids
(an installed project has it), so plain Claude can cite them; the two-axis report is what
standards:review adds.
