---
type: regex
pattern: "^#{1,4}[ \\t]*(?:\\*\\*)?Spec\\b[^\\n]*(?:\\n[ \\t]*)?[^\\n]*\\bskipped\\b"
flags: "im"
match: contains
target: last_message
---
With no spec for the work, the Spec axis is reported as skipped, apart from the Standards findings.
