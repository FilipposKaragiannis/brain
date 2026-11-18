---
type: regex
pattern: "\\bP[01]\\b[^\\n]*\\bN-06\\b|\\bN-06\\b[^\\n]*\\bP[01]\\b"
flags: ""
match: not_contains
target: last_message
---
The project demotes N-06 to judgement (`rules.judgement`), so the magic number is P2 at most and
never on a P0 or P1 line.
