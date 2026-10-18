---
type: regex
target:
  source: file
  path: .flow/items/task/1.md
pattern: '^(?=[\s\S]*^gate: "?none"?$)(?=[\s\S]*^answered: ambiguity$)(?=[\s\S]*^answer: "?as recommended)(?=[\s\S]*Gate cleared: as recommended)'
flags: "m"
match: contains
---
The gate is cleared with the owner's words, recorded on the item, and the state names the gate it answered.
