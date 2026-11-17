---
type: regex
pattern: "\\bP0\\b[^\\n]*\\bD-09\\b|\\bD-09\\b[^\\n]*\\bP0\\b"
flags: ""
match: contains
target: last_message
---
D-09 stays a hard rule in this project, so the optional parameter is graded P0: relaxing two rules
leaves the others as they are.
