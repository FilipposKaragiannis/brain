---
type: regex
target:
  source: file
  path: notes.md
pattern: '^(?=[\s\S]*^- #bug greet with two names greets only the first)(?=[\s\S]*^- What does tests/run\.sh check\?$)(?=[\s\S]*^- greet a stranger when the name is missing$)(?=[\s\S]*^- #idea print the greeting in green$)'
flags: "m"
match: contains
---
The skill never edits the notes file: the job removes the handled notes, not the skill.
