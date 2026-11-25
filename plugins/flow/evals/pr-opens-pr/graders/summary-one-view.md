---
type: regex
target:
  source: file
  path: .fake-gh/issues.json
pattern: '"pr": \{[^{}]*?"body": "(?:[^"\\]|\\.)*?\\n## Summary[ ]*\\n(?:(?!```)(?!\\n## )(?:[^"\\]|\\.))*(?:```(?:(?!```)(?!\\n## )(?:[^"\\]|\\.))*){0,2}\\n## '
flags: ""
match: contains
---
The Summary holds at most one fenced view, because the summary keeps one diagram and never several: two fences open and close one view, a third opens a second.
