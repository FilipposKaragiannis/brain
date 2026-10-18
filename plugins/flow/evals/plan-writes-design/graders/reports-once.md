---
type: regex
pattern: "^(?=[\\s\\S]*design\\.md)(?=[\\s\\S]*explore\\.md)(?=[\\s\\S]*\\bsize\\b)(?=[\\s\\S]*\\bgate\\b)"
flags: "i"
match: contains
target: last_message
---
The final message names design.md and explore.md, states the item's size, and says whether a gate was raised.
