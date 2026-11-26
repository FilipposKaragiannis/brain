---
type: regex
target:
  source: file
  path: .pool/wt-1/.flow/reports/local-task-1/verify.md
pattern: '^Verdict: (?:pass|fail) at [0-9a-f]{40}\n[0-2] of 2 acceptance lines proven live or by test\n'
flags: ""
match: contains
---
The line after the verdict counts the item's two acceptance lines, so a run that wrote no proofs
file, which counts 0 of 0, fails.
