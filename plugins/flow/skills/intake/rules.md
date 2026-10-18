# Intake rules

How a note becomes an item: the owner's choices, not the job's. These are flow's defaults. A
project that wants its own copies this file to `.flow/intake.md` (or the path in
`intake.rules`) and edits it; the intake skill reads that file instead of this one.

## Outcome

- Every note ends filed, a duplicate, done, answered or dropped. Nothing is parked for later:
  `#parked` is a tag like any other, and a note you can file is filed.
- **Done** only with code evidence: the behaviour the note asks for exists and is tested. The
  file and line go in `reason`. When unsure, file it.
- **Answered**: a `question` note, or one that asks what something is, why it behaves so, or how
  it works, is for the owner to understand, not work to do. Answer it from the code and the
  docs. The answer leads with the answer in one or two sentences, then the evidence as
  `file:line` and doc links, then what is unknown and what would settle it. When the answer
  shows a gap that needs work, file that item too.
- **Dropped** only for a reason the owner can check: the code it names is gone, a decision or a
  doc retired it (name it), or an open or closed item already did it (name it). Vague, old or
  hard is never a reason: file it, and gate it when it needs the owner.
- **Split** a note that asks for two unrelated things into one item each.

## The item

- **Type** from the tags first, then the section, then the note's words, named from `types`.
  With no `types`, the kind alone (`bug` or `task`).

  | Tag | Type |
  |---|---|
  | `#bug` | Bug |
  | `#feature`, `#idea` | Feature |
  | `#task`, `#experiment` | Task |
  | `#perf` | Task; Bug when something got slower |
  | `#rule` | Chore (a rule doc change) |

- **Area** from the section's top heading, matched to the closest of `areas`. A section that
  names a kind of work, not a part of the product (Bugs, Performance, Experiments), takes the
  area of the code the note touches. No match, or no `areas`: no area, and the body names the
  section.
- **Size** when it is clear (`S`, `M`, `L`).
- **Parent** only when the note names the epic: a sub-item holds its epic open until it closes,
  so name a related epic in `## Notes` instead.
- **Notes:** the note's own words in `## Notes`, quoted, with the section.
- **Priority:** suggest it, never set it. One line in `## Notes`:
  `Suggested priority: P<n>, <the reason in one clause>.` The owner sets the field, and an item
  without one is not ready.

## Needs the owner

A note that cannot become binary acceptance lines without a choice only the owner can make (what
"feels robotic" should become, which of two designs) is filed anyway, then gated with the
questions, each with its recommended answer. A question you can answer from the code is not one
for the owner.
