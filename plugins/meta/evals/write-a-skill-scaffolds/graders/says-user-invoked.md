---
type: regex
pattern: "user[- ]invo(?:ked|cation)|disable-model-invocation|invoked (?:only )?(?:by hand|by the user|manually)|invocation\\W+user|only (?:the )?users? (?:can )?invoke|(?:never|not) (?:be )?(?:model[- ]invoked|invoked by the model)|model invocation (?:is )?(?:off|disabled)"
flags: "i"
match: contains
target: last_message
---
The final message says the skill is user-invoked.
