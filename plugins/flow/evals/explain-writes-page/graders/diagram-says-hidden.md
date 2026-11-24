---
type: regex
target:
  source: file
  path: .pool/wt-1/.flow/reports/local-task-1/explain.html
pattern: 'class=["\x27][^"\x27]*\bmermaid\b[\s\S]*?</(?:pre|div)>(?:(?!<h2\b)[\s\S])*?(?:hide|hidden|left out|leaves? out|not shown|omit)'
flags: "i"
match: contains
---
The text under the diagram, in its section, says what the diagram hides.
