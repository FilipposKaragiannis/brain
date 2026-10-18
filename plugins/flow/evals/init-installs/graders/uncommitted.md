---
type: regex
pattern: "uncommitted|not (?:yet )?(?:been )?committed|nothing (?:is |has been |was )?(?:yet )?committed|(?:haven't|have not|did not|didn't) commit"
flags: "i"
match: contains
target: last_message
---
The report says the changes are not committed.
