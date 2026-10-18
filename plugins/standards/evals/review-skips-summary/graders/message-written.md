---
type: regex
pattern: "(feat|fix|refactor)(\\([a-z-]+\\))?!?: .*(discount|pric)"
flags: "i"
match: contains
target: last_message
---
The answer gives a conventional commit subject about the member discount or the pricer.
