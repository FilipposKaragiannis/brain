---
type: regex
target:
  source: file
  path: .flow/items/task/1.md
pattern: '\*\*Gate: ambiguity\*\*\s+1\.[^\n]*\?[^\n]*\n\s*Recommended:[^\n]+\n\s*2\.[^\n]*\?[^\n]*\n\s*Recommended:[^\n]+'
flags: ""
match: contains
---
The gate comment on the item asks numbered questions, each followed by its recommended answer.
