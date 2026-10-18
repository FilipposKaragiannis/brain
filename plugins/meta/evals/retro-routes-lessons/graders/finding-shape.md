---
type: regex
pattern: "^(?=[\\s\\S]*what happened)(?=[\\s\\S]*\\bchange\\b)(?=[\\s\\S]*where it lands)"
flags: "i"
match: contains
target: last_message
---
Each finding is stated as what happened, the change, and where it lands.
