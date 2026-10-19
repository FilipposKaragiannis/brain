---
type: regex
target:
  source: file
  path: .flow/tmp/intake-eval/results.json
pattern: '\{(?=[^{}]*"note"\s*:\s*"n3")(?=[^{}]*"outcome"\s*:\s*"duplicate")(?=[^{}]*"local:task/1")[^{}]*\}'
flags: ""
match: contains
---
The note that repeats the open item is a duplicate of local:task/1, not a new item.
