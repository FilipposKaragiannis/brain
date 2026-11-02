---
name: explain
description: Explain an item's change in plain language as a self-contained HTML page with diagrams, plus a short quiz the owner takes in the console before merge. Optional step, on by default for L tasks. Use when the user asks to explain a change or when the next step of an item is explain.
disable-model-invocation: true
---

Explain one item's change. Spawn a general subagent (no roster role) with this brief; it
writes `<reports>/explain.html` and `<reports>/quiz.md`. Plugin root `$P`: the directory
holding this skill.

`<reports>` is the reports folder the `next.sh` brief names. Run outside `next.sh`, it is the
path `"$P/scripts/steward.sh" reports <item>` prints, with the id as `gh#<n>` or
`local:<kind>/<n>`. Never build the path by hand.

## The page (`explain.html`)

Self-contained: inline CSS, Mermaid from `https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs`
for graph-shaped diagrams, no other network. Plain English: one idea per sentence, the
project's glossary words, no code in prose. Sections:

1. **What changed, in one paragraph.** The user-visible effect first.
2. **Why.** The problem from the item, in two or three sentences.
3. **How it works.** One picture per moving part: a call tree, a state diagram or a sequence
   diagram (Mermaid), each with a two-sentence caption. The key decision from `design.md` and
   the rejected alternative with its reason.
4. **What to look at by hand.** The feel-test list from `verify.md` when there is one.
5. **Where it lives.** A shallow file tree of the touched files with a five-word job each.

Inputs: the diff (`git diff <base>...HEAD`), `plan.md`, `design.md`, `verify.md`, the item.

## The quiz (`quiz.md`)

Three to five questions a reader of the page can answer, each pinning one thing the owner
must understand before merging: a behaviour change, a decision, a risk. Multiple choice only,
two to four choices, one right answer, and a `Because:` line that says why the right choice is
right (the owner reads it with their result). Format:

```markdown
<!-- flow:quiz -->
## Quiz for <item>
1. <question>
   a) <choice>
   b) <choice>
   c) <choice>
   Because: <why the right choice is right, one or two sentences>
...
<!-- answers: 1b 2a 3c -->
```

Then run `"$P/scripts/quiz.sh" show <item>` and fix the file until every question lists its
choices, its answer and its Because line. The owner takes the quiz in the console, on the Gates
and Pull requests pages (`quiz.sh answer` from a terminal), which grades it, keeps the result
as `<reports>/quiz.json` and marks the draft PR ready on a pass. Nothing of the quiz goes on the
PR.

## Result

`<reports>/explain.json`: status `done` with the two paths and the question count. Report
once with the page path; open it for the owner when a browser tool exists.
