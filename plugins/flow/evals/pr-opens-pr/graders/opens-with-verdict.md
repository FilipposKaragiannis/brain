---
type: regex
target:
  source: file
  path: .fake-gh/issues.json
pattern: '"pr": \{[^{}]*?"body": "Verdict: pass at [0-9a-f]{7,40}\b'
flags: ""
match: contains
---
The body's first line is the verify verdict, pass, with the commit verify ran on, because the reviewer learns from that line alone whether the work is proven. The fixture's report predates the verdict line, so the step builds it from verify.json.
