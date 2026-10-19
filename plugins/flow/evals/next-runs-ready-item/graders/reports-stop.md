---
type: regex
pattern: '^(?=[\s\S]*local:task/1)(?=[\s\S]*https://gh/pull/91)(?=[\s\S]*\bmerge\b)'
flags: "i"
match: contains
target: last_message
---
The report names the item, the PR and the merge gate it waits at.
