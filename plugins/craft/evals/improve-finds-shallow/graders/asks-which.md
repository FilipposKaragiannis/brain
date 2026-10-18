---
type: regex
pattern: "\\bwhich\\b[^\\n]*\\?[*_\\s]*$"
flags: "i"
match: contains
target: last_message
---
The message ends by asking the user which candidate to explore.
