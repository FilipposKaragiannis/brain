# PR body

The default body when the repo has no `.github/PULL_REQUEST_TEMPLATE.md`. For a reviewer who
wants to know, fast: what changed, does it work, how bad is it if it is wrong. Glossary words
only. No preamble.

```markdown
## Summary

<one or two sentences, then one view: pseudocode, call tree, file tree, diff sketch or Mermaid>

<the output of `scripts/pr-report.sh <reports>`, pasted whole: the `## Verification` section>

## Review

<P1 findings from the review step that were declared, one line each; "none" when clean. Never an
unmet acceptance line: the review step sends that back to implement>

## Merge danger

**Door:** <two-way: a revert undoes it | one-way: a revert does not, because ...>
**Blast radius:** <what breaks if this is wrong, in one or two words: one screen, every project, nothing shipped>

Resolves #<n>
```

- **Summary view**: pick the smallest that makes the point. Pseudocode for logic; a call tree
  for runtime flow; a file tree for a broad refactor; a diff sketch when the shape exists and
  the point is what changes; Mermaid for interaction between parts. One, never all.
- **Verification**: the script's output, never edited by hand. It carries the verdict, the
  proofs and the Not checked list; the full report stays in the reports folder.
- **Door**: how hard the merge is to undo. Two-way rolls back with a revert; one-way does not
  (migrations, destructive actions, published APIs, anything consumers build on). Say why for a
  one-way door.
- **Blast radius**: how much is affected if the change is wrong, in one or two words the reader
  can picture: "one screen", "the Gates page", "every flow project", "nothing shipped yet".
- A local item gets `Item: local:<kind>/<n>` instead of `Resolves`.
