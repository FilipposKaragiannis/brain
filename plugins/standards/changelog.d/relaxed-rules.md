bump: minor

- A project relaxes the rules that clash with its house style in `.standards/config.json`:
  `rules.relaxed` lists the rule ids it waives, `rules.judgement` the hard or signal rule ids it
  grades as [judgement]. `init` drops a waived rule's line from `.standards/rules/` and
  `.claude/rules/standards-*.md`, tags a demoted one `[judgement, relaxed from hard by this
  project]`, and moves both out of the block's hard rules and signals into a
  `## Waived by this project` and a `## Judgement in this project` list. Re-run `init` after
  editing the lists. A project without them gets the same files as before.
- An unknown id, a usage rule, a `judgement` id that is not hard or signal, an id in both lists,
  or an id a plugin hook enforces (C-01, C-02, W-01, L-03; the gap names the hook and its switch)
  is an `init` gap, so `init --check` exits 1 until it is fixed.
- The review skill and the standards, test and performance reviewers never raise a waived rule
  and grade a demoted one P2 at most. The project-advisor routes a rule the house style breaks on
  purpose to the two lists, and new configs carry them empty.
