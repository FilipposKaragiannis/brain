---
type: regex
target:
  source: file
  path: .flow/items/task/2.md
pattern: '^(?=[\s\S]*^## Problem$)(?=[\s\S]*^## Outcome$)(?=[\s\S]*^## Acceptance\n(?:\n)?- \[ \] [^\n]*shout)(?=[\s\S]*^title: (?:\S+ ){0,8}\S+$)(?=[\s\S]*^size: S$)'
flags: "m"
match: contains
---
The body has the item shape with a binary acceptance line about shouting, the title is under ten
words, and the size is S.
