---
type: regex
target:
  source: file
  path: .pool/wt-1/.flow/reports/local-task-1/explain.html
pattern: 'class=["\x27][^"\x27]*\bmermaid\b'
flags: "i"
match: contains
---
The page has a diagram: a Mermaid block.
