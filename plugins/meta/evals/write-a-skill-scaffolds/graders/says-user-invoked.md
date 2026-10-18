---
type: regex
pattern: "user[- ]invoked|disable-model-invocation|invoked by hand|invocation\\W+user"
flags: "i"
match: contains
target: last_message
---
The final message says the skill is user-invoked.
