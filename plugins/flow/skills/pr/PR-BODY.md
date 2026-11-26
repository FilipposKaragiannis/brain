# PR body

The default body when the repo has no `.github/PULL_REQUEST_TEMPLATE.md`. For a reviewer who
wants to know, fast: is it proven, what changed, how bad is it if it is wrong. Glossary words
only. No preamble: the verdict is the first line, then these three sections in this order,
with these headings and no others.

```markdown
Verdict: pass at <sha>, <n> of <m> acceptance lines proven live or by test

## Summary

<one or two sentences, then one view: pseudocode, call tree, file tree, diff sketch or Mermaid>

## Verification

<the verify.md table>

- **Before:** <failing test or output>
  **After:** <passing test or output>

**Not checked:**
- <acceptance line>: <build-only or blocked>, <why>

**Review:** <P1 findings from the review step that were declared, one line each; "none" when
clean. Never an unmet acceptance line: the review step sends that back to implement>

## Merge danger

**Door:** <two-way: a revert undoes it | one-way: a revert does not, because ...>
**Blast radius:** <what breaks if this is wrong, in one or two words: one screen, every project, nothing shipped>

Resolves #<n>
```

- **Verdict**: the first line of `verify.md` when it starts with `Verdict:`, copied as it is.
  An older report without one: build it from `verify.json`, its `status` and its `head` (the
  commit verify ran on, short form), and count the acceptance lines the `verify.md` table
  proves by a test or a live run.
- **Summary view**: one view, never several. Pick the smallest that makes the point.
  Pseudocode for logic; a call tree for runtime flow; a file tree for a broad refactor; a diff
  sketch when the shape exists and the point is what changes; Mermaid for interaction between
  parts.
- **Verification**: the verify table is required; a before/after test or output when the change
  is observable; a screenshot when it is visual and one can be captured.
- **Not checked**: always there. The Not checked list of `verify.md`, else the acceptance lines
  its table leaves unproven or proves only by a build, plus the feel-test when verify flags one.
  One line, `- nothing`, when every line is proven.
- **Door**: how hard the merge is to undo. Two-way rolls back with a revert; one-way does not
  (migrations, destructive actions, published APIs, anything consumers build on). Say why for a
  one-way door.
- **Blast radius**: how much is affected if the change is wrong, in one or two words the reader
  can picture: "one screen", "the Gates page", "every flow project", "nothing shipped yet".
- A local item gets `Item: local:<kind>/<n>` instead of `Resolves`.
- With a repo template, the verdict line still goes first, above the template's sections.
