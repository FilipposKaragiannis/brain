---
type: regex
target:
  source: file
  path: .fake-gh/issues.json
pattern: '"pr": \{[^{}]*?"body": "(?:[^"\\]|\\.)*?\\n## Verification[ ]*\\n(?:(?!\\n## )(?:[^"\\]|\\.))*?Not checked[^"\\]*\\n(?:\\n)?- \S'
flags: ""
match: contains
---
The Verification section has a Not checked list with at least one item, because the list is always there, even when it says nothing.
