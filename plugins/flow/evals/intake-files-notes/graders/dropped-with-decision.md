---
type: regex
target:
  source: file
  path: .flow/tmp/intake-eval/results.json
pattern: '\{(?=[^{}]*"note"\s*:\s*"n4")(?=[^{}]*"outcome"\s*:\s*"dropped")(?=[^{}]*decisions\.md)[^{}]*\}'
flags: ""
match: contains
---
The colour idea is dropped, and the reason names the decision record that retired it.
