---
type: regex
pattern: "\\?[*_`\\s]*$|\\bapply\\b[^\\n?]*\\?"
flags: "i"
match: not_contains
target: last_message
---
The retro runs unattended: it does not end on a question or ask which findings to apply.
