---
type: regex
pattern: "review|missing or unclear|\\?[*_`\\s]*$"
flags: "i"
match: contains
target: last_message
---
The final message hands the skill to the user for review (asks what is missing or unclear).
