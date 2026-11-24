---
type: regex
target:
  source: file
  path: .pool/wt-1/.flow/reports/local-task-1/explain.html
pattern: '<body\b(?:(?!<h2\b)[\s\S])*?(?:<h2\b(?:(?!<h2\b)[\s\S])*?)?verif'
flags: "i"
match: contains
---
The page opens with the verify verdict: the first section, before the second heading, says whether the change is verified (here it is not yet, the fixture has no verify report).
