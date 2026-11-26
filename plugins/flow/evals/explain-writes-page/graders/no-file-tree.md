---
type: regex
target:
  source: file
  path: .pool/wt-1/.flow/reports/local-task-1/explain.html
pattern: '[├└│]──|<h[1-6][^>]*>[^<]*\bfile (?:tree|list)'
flags: "i"
match: not_contains
---
The file tree section is gone: no tree drawing and no file tree heading.
