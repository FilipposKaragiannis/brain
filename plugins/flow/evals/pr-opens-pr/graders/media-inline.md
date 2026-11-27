---
type: regex
target:
  source: file
  path: .fake-gh/issues.json
pattern: '"pr": \{[\s\S]*?"body": "(?:[^"\\]|\\.)*https://gh/assets/'
flags: ""
match: contains
---
The stored PR body points at the uploaded screenshot's asset URL, so it renders inline.
