---
name: intake
description: Turn the owner's raw notes into tracker items. Reads a notes JSON from the intake job, checks each note against the open items and the code, and by the project's intake rules files it as a typed item in its area, names the item it duplicates, answers it on a report page or drops it with a stated reason, gates the ones that need the owner, and writes a results file. Use when the intake job runs, or when the owner asks to file their notes, triage a notes file, or turn a backlog file into issues.
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

`notes.json`: `{"notes": [note], "left": N, "types": [...], "areas": [...], "rules": "<path>"}`.
`types` are the tracker's issue types and `areas` its area options; either is empty when the
tracker has none. `rules` is the intake rules file: the project's (`intake.rules`, default
`.flow/intake.md`) or, without one, flow's defaults in this skill's `rules.md`.
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

**Read `rules` first.** It is the owner's: it decides when a note is done, answered or dropped,
when to split it, its type, area, size, parent and suggested priority, what its `## Notes` hold
and when it needs the owner. Follow it over anything here; the steps below are how to carry it
out.

1. **List the open items** fresh: `"$P/adapters/<adapter>/list.sh"`. The note before yours may
   have just filed the item yours duplicates.
2. **Duplicate?** An open item that already covers the ask: outcome `duplicate` with its id. A
   `dup` handle whose `related` entry has issues names it. If the note adds a detail the item
   lacks (a repro, a case), add it as a comment on that item. A `dup` of a note that has no item:
   - `dropped`: drop this one too, `reason` "Same as ^id, dropped: " and that note's reason.
   - `done`: outcome `done`, with that note's reason.
   - `answered`: outcome `dropped`, `reason` "Answered with ^id on the answers page."
   - empty: not handled yet; judge the note on its own.
3. **Decide the outcome** by the rules: `done` with its evidence in `reason`, `answered` with a
   `title` that is the question and an `answer` in Markdown (any item the answer files goes in
   `issues`), `dropped` with its evidence in `reason`, else filed, split as the rules say.
4. **Look at the code just enough** to confirm what the note describes: grep, read the entry
   point. No exploration agents, no plan, at most a few minutes a note.
5. **File it** with the `new` skill's shape and script (`"$P/scripts/new.sh"`): the type from
   `types` with `--type`, the area from `areas` with `--area`, the size and parent as the rules
   pick them. In `## Notes`, after what the rules put there, one line `Related: gh#12, gh#40.`
   for the `related` entries with issues; a `related` handle with no issues is left out, since
   that note names this one when it is filed.
6. **Needs the owner?** When the rules say so, file it anyway, then raise the gate with the
   questions in the gate skill's format (numbered, one per line, each with its recommended
   answer): `"$P/scripts/gate.sh" raise <id> ambiguity "<questions>"`. Mark the result
   `needs_owner`.

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

- Never edit the notes file, the answers and dropped pages, or the rules file.
- Never keep a note to park it for later.
- Never mark a note `done` without code evidence, or `duplicate` without the item's id.
- Never start work on an item: no claim, no worktree, no plan.
