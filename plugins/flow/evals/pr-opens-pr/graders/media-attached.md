---
type: regex
target:
  source: file
  path: .fake-gh/issues.json
pattern: '"assets": \[[^\]]*/evidence/screen\.png"'
flags: ""
match: contains
---
The fake GitHub holds the verify capture's screenshot as an uploaded asset of the PR.
