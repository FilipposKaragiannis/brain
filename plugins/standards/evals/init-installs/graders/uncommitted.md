---
type: regex
pattern: "uncommitted|not (?:yet )?(?:been )?committed|(?:nothing|none(?: of (?:it|them|this|these))?) (?:is |are |has been |have been |was |were )?(?:yet )?committed|(?:haven't|have not|did not|didn't) commit"
flags: "i"
match: contains
target: last_message
---
The report says the changes are not committed.
