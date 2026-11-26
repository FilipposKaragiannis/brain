---
type: regex
target:
  source: file
  path: .pool/wt-1/.flow/reports/local-task-1/explain.html
pattern: 'class=["\x27][^"\x27]*\bmermaid\b[^>]*>(?:(?=((?:(?!</(?:pre|div)>|(?:--?>>?|==>|--[xo)]|-\.->))[\s\S])*))\1(?:--?>>?|==>|--[xo)]|-\.->)){21}'
flags: "i"
match: not_contains
---
The diagram has at most 20 arrows.
