---
type: regex
pattern: "^[ \\t]*(?:\\*\\*)?\\d+[.)][^\\n]*testing-guide\\.md"
flags: "m"
match: contains
target: last_message
---
The gaps the installer reported for the testing guide's placeholders are in a numbered list, the
owner answers item by item, in the same final message as the files.
