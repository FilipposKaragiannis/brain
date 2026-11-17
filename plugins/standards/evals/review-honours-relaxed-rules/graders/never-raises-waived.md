---
type: regex
pattern: "\\bP[0-2]\\b[^\\n]*\\bD-10\\b|\\bD-10\\b[^\\n]*\\bP[0-2]\\b"
flags: ""
match: not_contains
target: last_message
---
The project waives D-10 (`rules.relaxed`), so the static counter is never raised: no graded line
names D-10, though the review may say the rule is waived.
