---
name: explain
description: Explain an item's change in plain language as a self-contained HTML page that opens with the verify verdict and shows one diagram, plus a short quiz the owner takes in the console before merge. Optional step, on by default for L tasks. Use when the user asks to explain a change or when the next step of an item is explain.
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
for the diagram, no other network. Plain English: one idea per sentence, the project's glossary
words, no code in prose. Nothing on it repeats the PR body: no summary view, no verify table, no
file list. Sections, in this order:

1. **What changed, and is it verified.** The first lines of the page: the user-visible change
   in one or two sentences, then the verdict from the first line of `verify.md`. With no
   `verify.md`, the verdict line says the change is not verified yet.
2. **Why.** The problem from the item, in two or three sentences.
3. **One example.** One concrete case traced through the change, step by step: what the user
   does, what happens at each step, what the user sees at the end, and what they saw before.
4. **How it works.** One diagram (Mermaid): a call tree, a state diagram or a sequence diagram,
   whichever makes the point, with a two-sentence caption. A second diagram only when the
   change has a part the first cannot show, and its caption states that reason. The key
   decision from `design.md` and the rejected alternative with its reason.
5. **What to check by hand.** What no test or live run proved: the Not checked list in
   `verify.md` and the feel-test when there is one, each as one thing the owner does and what
   they should see. "Nothing" when every line is proven.

Every diagram keeps these rules:

- A box or arrow is labelled with what the reader sees: a screen, a button, a step, a message.
  Variable, field, function and class names stay out.
- About 20 arrows at most. Past that, merge boxes or drop the minor steps.
- One line under it says what it hides (e.g. "Left out: the error paths and the config read").

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
