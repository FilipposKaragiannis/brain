---
type: regex
target:
  source: file
  path: .flow/config.yaml
pattern: '^jobs:[ \t]*\n(?:[ \t]+[^\n]*\n)*?[ \t]+schedule:[ \t]*\n(?:[ \t]+[^\n]*\n)*?[ \t]+next:[ \t]*"?every 30m'
flags: "m"
match: contains
---
The schedule lives in the config: jobs.schedule.next is every 30m.
