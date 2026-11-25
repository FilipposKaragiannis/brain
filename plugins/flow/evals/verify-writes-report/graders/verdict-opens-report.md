---
type: regex
target:
  source: file
  path: .pool/wt-1/.flow/reports/local-task-1/verify.md
pattern: '^Verdict: (?:pass|fail) at [0-9a-f]{40}\n[\s\S]*\n## Not checked\n'
flags: ""
match: contains
---
The Markdown report opens with the verdict at the full 40-character commit and ends with a Not
checked section.
