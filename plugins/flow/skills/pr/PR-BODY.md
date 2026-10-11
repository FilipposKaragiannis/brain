# PR body

The default body when the repo has no `.github/PULL_REQUEST_TEMPLATE.md`. For a reviewer who
wants to know, fast: what changed, does it work, how bad is it if it is wrong. Glossary words
only. No preamble.

```markdown
## Summary

<one or two sentences, then one view: pseudocode, call tree, file tree, diff sketch or Mermaid>

## Evidence

<the verify.md table>

- **Before:** <failing test or output>
  **After:** <passing test or output>

## Review

<P1 findings from the review step that were declared, one line each; "none" when clean>

## Merge danger

**Door:** <one-way or two-way>
**Blast radius:** <one word>

Resolves #<n>
```

- **Summary view**: pick the smallest that makes the point. Pseudocode for logic; a call tree
  for runtime flow; a file tree for a broad refactor; a diff sketch when the shape exists and
  the point is what changes; Mermaid for interaction between parts. One, never all.
- **Evidence**: the verify table is required; a before/after test or output when the change
  is observable; a screenshot when it is visual and one can be captured.
- **Door**: two-way rolls back with a revert; one-way does not (migrations, destructive
  actions, published APIs, anything consumers build on).
- A local item gets `Item: local:<kind>/<n>` instead of `Resolves`.
