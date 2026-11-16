---
type: regex
target:
  source: file
  path: .main/.flow/items/task/1.md
pattern: '^gate: "?merge"?$'
flags: "m"
match: contains
---
advance.sh applied the result and the profile's merge gate stopped the run.
