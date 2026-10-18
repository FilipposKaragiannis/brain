---
type: regex
pattern: "\\b(?:\\d+|one|two|three|four|five|six|seven|eight|nine|ten)[- ](?:[\\w-]+ )?questions?\\b"
flags: "i"
match: contains
target: last_message
---
The final message says how many quiz questions there are.
