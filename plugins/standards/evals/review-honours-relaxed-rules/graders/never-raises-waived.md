---
type: regex
pattern: "^(?![^\\n]*\\b(?:[Ww]aive|[Rr]elax))[^\\n]*(?:\\bP[0-2]\\b[^\\n]*\\bD-10\\b|\\bD-10\\b[^\\n]*\\bP[0-2]\\b)"
flags: "m"
match: not_contains
target: last_message
---
The project waives D-10 (`rules.relaxed`), so the static counter is never raised: no line grades
D-10. A line that explains the waiver (it says waived or relaxed) is not a finding and may name
D-10 next to a grade.
