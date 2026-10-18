---
type: regex
pattern: "\\b(?=[0-9a-f]*\\d)[0-9a-f]{7,40}\\b|implement\\.json"
flags: ""
match: contains
target: last_message
---
The final message names the commit (its hash) or the result file (implement.json).
