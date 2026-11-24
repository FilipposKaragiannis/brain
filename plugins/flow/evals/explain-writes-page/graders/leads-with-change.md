---
type: regex
target:
  source: file
  path: .pool/wt-1/.flow/reports/local-task-1/explain.html
pattern: '<body\b(?:(?!<h2\b)[\s\S])*?(?:<h2\b(?:(?!<h2\b)[\s\S])*?)?(?:hello stranger|(?:no|without a|without any|missing|empty) (?:name|argument))'
flags: "i"
match: contains
---
The page opens with the user-visible change: the first section, before the second heading, says what a call with no name now does.
