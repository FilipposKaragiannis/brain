---
type: regex
pattern: "(?:^|\\n)[ \\t]*(?:\\*\\*)?\\d+[.)][^\\n]*doc_inside[^\\n]*(?:\\n(?![ \\t]*(?:\\*\\*)?\\d+[.)])[^\\n]*)*$"
flags: ""
match: contains
target: last_message
---
The last numbered item of the gap list is the doc_inside question about container kinds.
