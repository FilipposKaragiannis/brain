---
type: regex
pattern: "\\bP0\\b[^\\n]*\\b(?:D-09|D-10|N-06|C-01)\\b|\\b(?:D-09|D-10|N-06|C-01)\\b[^\\n]*\\bP0\\b"
flags: ""
match: contains
target: last_message
---
A broken hard rule is graded P0 on its finding.
