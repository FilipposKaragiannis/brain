---
type: regex
target:
  source: file
  path: .fake-gh/issues.json
pattern: '"pr": \{[^{}]*?"body": "(?:[^"\\]|\\.)*?\\n## Verification[ ]*\\n(?:(?!\\n## )(?:[^"\\]|\\.))*?Not checked[^"\\]*\\n(?:\\n)?- nothing\.?(?!\\n- )(?:\\n|")'
flags: ""
match: contains
---
The Not checked list says nothing and holds no other line, because the report proves every acceptance line by test and the list is there even when it is empty.
