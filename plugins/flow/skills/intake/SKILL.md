---
name: intake
description: Turn the owner's raw notes into tracker items. Reads a notes JSON from the intake job, checks each note against the open items and the code, files it as a typed, sized item in its area with a suggested priority, answers the questions on a report page, drops a note only with a stated reason, gates the ones that need the owner, and writes a results file. Use when the intake job runs, or when the owner asks to file their notes, triage a notes file, or turn a backlog file into issues.
disable-model-invocation: true
---

Turn notes into items. The intake job (`jobs/intake.sh`) owns the notes file: it runs one
session per note, hands you that note as `notes.json` and, from your `results.json`, records what you handled and removes it
from the file. You never edit the notes file.

Plugin root `$P`: the directory holding this skill (`${CLAUDE_PLUGIN_ROOT}` on Claude; on Codex
the path `codex plugin list` prints for `flow`).

Asked in a session without a `notes.json` ("file my notes"): run
`"$P/jobs/intake.sh" claude` (or `codex`) from the main worktree, or with `--notes <file>` for
another file, and report its last log line. Do not file the notes by hand.

## Input

`notes.json`: `{"notes": [note], "left": N, "types": [...], "areas": [...]}`. `types` are the
tracker's issue types and `areas` its area options; either is empty when the tracker has none.
A note:

| Key | What it holds |
|---|---|
| `text` | the note as written, a bullet with its sub-lines (`desc:` is its description) |
| `title` | the first line without its checkbox, tags and handle |
| `section` | the chain of headings above it ("Bots", "tasks > Bot Bugs"): the area, and a hint at the kind |
| `tags` | the `#` tags on the first line (`bug`, `perf`, `question`, `parked`) |
| `ref`, `dup`, `rel` | its handle (`^id`), the handle it says it duplicates (`#dup (see ^id)`), the handles its `rel:` line names |
| `related` | for `dup`, `rel` and the handled notes that name this one: `{"ref", "issues", "outcome", "reason"}`, read from the ledger just before your session, so a note handled earlier in the same run is there. `outcome` is that note's (`filed`, `duplicate`, `done`, `answered`, `dropped`), empty when it is not handled yet; `reason` comes with a `done` or `dropped` one |
| `question` | tagged `#question`, or a title that ends with `?` |

## Per note

Every note ends as an item, a duplicate, done, answered or dropped. Nothing is parked for later:
`#parked` is a tag like any other, and a note you can file is filed.

1. **List the open items** fresh: `"$P/adapters/<adapter>/list.sh"`. The note before yours may
   have just filed the item yours duplicates.
2. **Duplicate?** An open item that already covers the ask: outcome `duplicate` with its id. A
   `dup` handle whose `related` entry has issues names it. If the note adds a detail the item
   lacks (a repro, a case), add it as a comment on that item. A `dup` of a note that has no item:
   - `dropped`: drop this one too, `reason` "Same as ^id, dropped: " and that note's reason.
   - `done`: outcome `done`, with that note's reason.
   - `answered`: outcome `dropped`, `reason` "Answered with ^id on the answers page."
   - empty: not handled yet; judge the note on its own.
3. **Done already?** Only with code evidence (the behaviour the note asks for exists and is
   tested), outcome `done` with the file and line in `reason`. When unsure, file it.
4. **A question?** A `question` note, or one that asks what something is, why it behaves so, or
   how it works, is for the owner to understand, not work to do. Answer it from the code and
   the docs: outcome `answered`, a `title` that is the question, and an `answer` in Markdown. The
   answer leads with the answer in one or two sentences, then the evidence as `file:line` and
   doc links, then what is unknown and what would settle it. When the answer shows a gap that
   needs work, file that item too and list it in `issues`.
5. **Drop it?** Only for a reason the owner can check: the code it names is gone, a decision or
   a doc retired it (name it), or an open or closed item already did it (name it). Outcome
   `dropped`, the reason in `reason` with its evidence. Vague, old or hard is never a reason:
   file it, and gate it when it needs the owner.
6. **Split** a note that asks for two unrelated things into one item each.
7. **Look at the code just enough** to confirm what the note describes: grep, read the entry
   point. No exploration agents, no plan, at most a few minutes a note.
8. **File it** with the `new` skill's shape and script (`"$P/scripts/new.sh"`):
   - **Type** from the tags first, then the section, then the note's words, named from `types`
     (with `--type`). With no `types`, the kind alone (`bug` or `task`).

     | Tag | Type |
     |---|---|
     | `#bug` | Bug |
     | `#feature`, `#idea` | Feature |
     | `#task`, `#experiment` | Task |
     | `#perf` | Task; Bug when something got slower |
     | `#rule` | Chore (a rule doc change) |

   - **Area** from the section's top heading, matched to the closest of `areas` (with
     `--area`). A section that names a kind of work, not a part of the game (Bugs,
     Performance, Experiments), takes the area of the code the note touches. No match, or no
     `areas`: no `--area`, and the body names the section.
   - **Size** when it is clear (`S`, `M`, `L`).
   - **Parent** only when the note names the epic: a sub-item holds its epic open until it
     closes, so name a related epic in `## Notes` instead.
   - **Notes:** the note's own words in `## Notes`, quoted, with the section. One line
     `Related: gh#12, gh#40.` for the `related` entries with issues; a `related` handle with
     no issues is left out, since that note names this one when it is filed. Add one line:
     `Suggested priority: P<n>, <the reason in one clause>.` Never set the priority field: the
     owner sets it, and an item without one is not ready.
9. **Needs the owner?** When the note cannot become binary acceptance lines without a choice
   only the owner can make (what "feels robotic" should become, which of two designs), file it
   anyway, then raise the gate with the questions in the gate skill's format (numbered, one per
   line, each with its recommended answer):
   `"$P/scripts/gate.sh" raise <id> ambiguity "<questions>"`. Mark the result `needs_owner`.
   A question you can answer from the code is not one for the owner.

## Output

Write `results.json` next to `notes.json`, one row per note it holds:

```json
[{"note": "n1", "outcome": "filed", "issues": ["gh#341"], "needs_owner": false, "reason": "..."},
 {"note": "n2", "outcome": "duplicate", "issues": ["gh#310"], "reason": "..."},
 {"note": "n3", "outcome": "answered", "issues": [], "title": "Why does a free rod swing?", "answer": "..."},
 {"note": "n4", "outcome": "dropped", "issues": [], "reason": "The net settings it names were removed in gh#120."},
 {"note": "n5", "outcome": "kept", "issues": [], "reason": "new.sh failed: ..."}]
```

Outcomes: `filed`, `duplicate`, `done`, `answered` and `dropped` are removed from the notes
file; the job appends each answer to the answers page and each dropped note with its reason to
the dropped page. `kept` stays for the next run, only for a tool failure or a note you could not
read; an `answered` row without an answer or a `dropped` row without a reason is kept too.
Write the file even when every note failed, so the job can tell a failed run from a crash.

## Never

- Never edit the notes file or the answers and dropped pages, and never set the priority field.
- Never keep a note to park it for later, and never drop one without a reason the owner can check.
- Never mark a note `done` without code evidence, or `duplicate` without the item's id.
- Never start work on an item: no claim, no worktree, no plan.
