---
type: regex
target:
  source: file
  path: .pool/wt-1/.flow/reports/local-task-1/explain.html
pattern: 'class=["\x27][^"\x27]*\bmermaid\b[\s\S]*class=["\x27][^"\x27]*\bmermaid\b'
flags: "i"
match: not_contains
---
The page has one diagram by default: the fixture change is one line and gives no reason for a second.
