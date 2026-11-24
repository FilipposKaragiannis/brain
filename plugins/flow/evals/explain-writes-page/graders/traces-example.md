---
type: regex
target:
  source: file
  path: .pool/wt-1/.flow/reports/local-task-1/explain.html
pattern: '<h[2-6][^>]*>[^<]*example(?:(?!<h[2-6]\b)[\s\S])*?hello stranger'
flags: "i"
match: contains
---
The page traces one concrete example: its example section shows the output a call with no name gives, "hello stranger".
