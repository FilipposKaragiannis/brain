---
type: regex
pattern: "review[\\s\\S]{0,80}?config\\.json|\\.standards/config\\.json[^\\n]*\\breview"
flags: "i"
match: contains
target: last_message
---
The report tells the owner to review .standards/config.json.
