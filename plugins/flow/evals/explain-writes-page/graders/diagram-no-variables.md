---
type: regex
target:
  source: file
  path: .pool/wt-1/.flow/reports/local-task-1/explain.html
pattern: 'class=["\x27][^"\x27]*\bmermaid\b[^>]*>(?:(?!</(?:pre|div)>)[\s\S])*?\$(?:\{|\d|[A-Za-z_])'
flags: "i"
match: not_contains
---
The diagram keeps variable names out: no shell variable such as $1 in it, because it labels what the reader sees.
