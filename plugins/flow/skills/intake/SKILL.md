---
name: intake
description: Turn the owner's raw notes into tracker items. Reads a notes JSON from the intake job, checks each note against the open items and the code, files it as a typed, sized item with a suggested priority, gates the ones that need the owner, and writes a results file. Use when the intake job runs, or when the owner asks to file their notes, triage a notes file, or turn a backlog file into issues.
disable-model-invocation: true
---

Turn notes into items. The intake job (`jobs/intake.sh`) owns the notes file: it hands you a
batch as `notes.json` and, from your `results.json`, records what you handled and removes it
from the file. You never edit the notes file.

Plugin root `$P`: the directory holding this skill (`${CLAUDE_PLUGIN_ROOT}` on Claude; on Codex
the path `codex plugin list` prints for `flow`).

Asked in a session without a `notes.json` ("file my notes"): run
`"$P/jobs/intake.sh" claude` (or `codex`) from the main worktree, or with `--notes <file>` for
another file, and report its last log line. Do not file the notes by hand.

## Input

`notes.json`: `{"notes": [{"id", "hash", "section", "text"}], "left": N}`. `text` is the note
as written, a bullet with its sub-lines. `section` is the chain of headings above it
("Bugs", "tasks > Bot Bugs and improvements"): a hint at the kind and the area, not a rule.

## Per note

1. **List the open items once** for the batch: `"$P/adapters/<adapter>/list.sh"`.
2. **Duplicate?** An open item that already covers the ask: outcome `duplicate` with its id. If
   the note adds a detail the item lacks (a repro, a case), add it as a comment on that item.
3. **Done already?** Only with code evidence (the behaviour the note asks for exists and is
   tested), outcome `done` with the file and line in `reason`. When unsure, file it.
4. **Split** a note that asks for two unrelated things into one item each.
5. **Look at the code just enough** to name the area and confirm what the note describes:
   grep, read the entry point. No exploration agents, no plan, at most a few minutes a note.
6. **File it** with the `new` skill's shape and script (`"$P/scripts/new.sh"`): the kind (and
   `--type` where the tracker has issue types), a size when it is clear (`S`, `M`, `L`), the
   parent epic when one plainly owns it. The note's own words go in `## Notes`, quoted,
   with the section. Add one line to `## Notes`:
   `Suggested priority: P<n>, <the reason in one clause>.` Never set the priority field: the
   owner sets it, and an item without one is not ready.
7. **Needs the owner?** When the note cannot become binary acceptance lines without a choice
   only the owner can make (what "feels robotic" should become, which of two designs), file it
   anyway, then raise the gate with the questions, numbered, each answerable in a sentence:
   `"$P/scripts/gate.sh" raise <id> ambiguity "<questions>"`. Mark the result `needs_owner`.
   A question you can answer from the code is not one for the owner.

## Output

Write `results.json` next to `notes.json`, one row per note in the batch:

```json
[{"note": "n1", "outcome": "filed", "issues": ["gh#341"], "needs_owner": false, "reason": "..."},
 {"note": "n2", "outcome": "duplicate", "issues": ["gh#310"], "reason": "..."},
 {"note": "n3", "outcome": "kept", "issues": [], "reason": "new.sh failed: ..."}]
```

Outcomes: `filed`, `duplicate` and `done` are removed from the notes file; `kept` stays for
the next run (a tool failure, a note you could not read). Write the file even when every note
failed, so the job can tell a failed run from a crash.

## Never

- Never edit the notes file, and never set the priority field.
- Never mark a note `done` without code evidence, or `duplicate` without the item's id.
- Never start work on an item: no claim, no worktree, no plan.
