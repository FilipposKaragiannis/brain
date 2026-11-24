---
type: regex
target:
  source: file
  path: .pool/wt-1/.flow/reports/local-task-1/explain.html
pattern: '<body\b(?:(?!<h2\b)[\s\S])*?<h2\b[^>]*>(?:(?!</h2>)[\s\S])*?</h2>(?:(?!<h2\b)[\s\S])*?(?:(?:\bnot|n\x27t)(?: yet)?(?: been)? verified|\bunverified)'
flags: "i"
match: contains
---
The page opens with the verify verdict: the first section's text, after its heading and before the second heading, says the change is not verified yet, because the fixture has no verify report. The heading's own "verified" does not count.
