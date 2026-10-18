---
type: regex
pattern: "review[\\s\\S]{0,80}?\\.flow/config\\.yaml|\\.flow/config\\.yaml[^\\n]*\\breview"
flags: "i"
match: contains
target: last_message
---
The report tells the owner to review .flow/config.yaml.
