---
type: regex
pattern: "^(?=[\\s\\S]*(?:\\breview|by hand))(?=[\\s\\S]*\\.flow/config\\.yaml)"
flags: "i"
match: contains
target: last_message
---
The report names .flow/config.yaml and lists what the owner reviews by hand.
