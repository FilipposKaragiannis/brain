---
type: regex
pattern: "(?:^|\\n)[ \\t]*(?:\\*\\*)?\\d+[.)][^\\n]*(?:\\n(?![ \\t]*(?:\\*\\*)?\\d+[.)])[^\\n]*){0,6}$"
flags: ""
match: contains
target: last_message
---
The numbered list of config questions closes the message: at most a few lines follow its last item.
