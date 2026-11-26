---
type: regex
target:
  source: file
  path: .fake-gh/issues.json
pattern: '"pr": \{[^{}]*?"body": "(?:(?!\\n## )(?:[^"\\]|\\.))*\\n## Summary[ ]*\\n(?:(?!\\n## )(?:[^"\\]|\\.))*\\n## Verification[ ]*\\n(?:(?!\\n## )(?:[^"\\]|\\.))*\\n## Merge danger[ ]*\\n(?:(?!\\n## )(?:[^"\\]|\\.))*"'
flags: ""
match: contains
---
The body has three sections, Summary, Verification and Merge danger, in that order and no others, because every PR body has the same shape for the reviewer.
