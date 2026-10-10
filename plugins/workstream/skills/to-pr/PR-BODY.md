# PR body

The default PR body when the repo has no `.github/PULL_REQUEST_TEMPLATE.md`. Built for a reviewer
who wants to know, fast: what changed, does it work, and how bad is it if it's wrong. Skip
preambles, keep prose brief, and use the repo's `## Glossary` terms.

```markdown
## Summary

<one or two sentences, then a diagram, diff-sketch, or tree>

## Evidence

- **Before:** <failing test run / output / screenshot>
  **After:** <passing test run / output / screenshot>

## Merge Danger

**Door:** <one-way or two-way>

**Blast radius:** <one word>

<optional: what could break on merge>

Resolves #<issue#>
```

## Summary — the smallest view that makes the point

Pick one, occasionally two. Never all of them.

- **Pseudocode** for logic or an algorithm.
- **Call tree** for runtime control flow (`submitForm → createSession → persistPrompt`).
- **Component tree** for UI structure, with the state and module boundaries that matter.
- **Shallow file tree** for file responsibilities or a broad refactor.
- **Mermaid** for interaction or data flow between parts.
- **A `diff` sketch** when the surrounding shape already exists and the point is what changes —
  match it to the topic (a call tree with `+`/`-` lines, a file tree with `+`/`-` lines):

  ```diff
   on(save)
  -  write content
  +  if content is unchanged
  +    return cached result
  +  write new content
  ```

Keep only the calls, files, and boundaries the reviewer needs. Put each visual beside the one line
of text it supports.

## Evidence — before and after

Gate 1 already ran the suite, so you have the material. Rank by strength:

- **Screenshots** — best, when the change is visual and the environment can capture one.
- **Execution** — the exact test that failed before and passes now (name it, sketch its steps as
  pseudocode), or console output before and after.

## Merge Danger

- **Door** — a *two-way door* rolls back cheaply (revert the commit, done). A *one-way door* does
  not: data migrations, destructive actions, published APIs, anything consumers will build on.
- **Blast radius** — the widest thing this could break: layout shift, consumers of an API,
  save-file compatibility, mobile layout. Consider all of it, then name it in one word.
