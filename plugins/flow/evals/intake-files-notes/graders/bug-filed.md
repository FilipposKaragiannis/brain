---
type: regex
target:
  source: file
  path: .flow/tmp/intake-eval/results.json
pattern: '\{(?=[^{}]*"note"\s*:\s*"n1")(?=[^{}]*"outcome"\s*:\s*"filed")(?=[^{}]*"local:bug/1")[^{}]*\}'
flags: ""
match: contains
---
The bug note is filed as a local bug item.
