---
type: regex
pattern: "not (?:been )?(?:edited|changed|applied|touched)|nothing (?:has been |was |is )?(?:yet )?applied|project changes:?\\**:?\\s*none|no project changes|(?:did not|didn't|have not|haven't) (?:edit|change|touch|apply)|left (?:the project )?unchanged|listed, not applied"
flags: "i"
match: contains
target: last_message
---
The retro says the project was not edited (project changes are listed, not applied).
