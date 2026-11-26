# meta

## 1.1.9 (2026-11-26)

- The map says each flow once. The Playbooks section is gone; what only it said, the stations,
  what each diamond wants from you, the commands that drive a line and the unattended and
  playtest-note runs, now sits in the Flows section.

## 1.1.8 (2026-11-21)

- The retro skill applies its marketplace changes in a throwaway worktree cut from the remote's
  default branch, pushes the branch, opens the PR and removes the worktree. It never switches the
  branch of the marketplace checkout or edits a file in it. Before, it worked on `retro/<date>` in
  the checkout the prompt named, which could be the one the owner works in and the jobs run from.
- It runs the tests its edits touch, the way the worktree's testing guide says, and never the
  whole `tools/test.sh`: CI runs that on the PR.

## 1.1.7 (2026-11-20)

- The retro reads the flow's graph report when the retro job names one: a step that got slower,
  fails often or runs more than twice per item is a finding, routed like a lesson.

## 1.1.6 (2026-11-16)

- `retro` no longer names the owner's own marketplace folder. It opens the marketplace only to
  apply findings the owner approved, at the path the prompt gives or the owner names, so the
  report rests on the lessons and the session alone.
- The retro report has a set shape: the findings under the labels What happened, The change and
  Where it lands, one change each; the lessons set aside, each with why; then the question which
  findings to apply. Asides such as checks that came up clean stay out.
- An unattended retro with no marketplace checkout puts the marketplace findings in its report,
  and its last message names the report and says the project was not edited.
- `write-a-skill` names a new failure mode, the literal limit: a word cap, a blanket ban or a line
  in capitals that current models follow to the letter. The no-op fix is a sharper completion
  criterion or the effort setting, not a louder word.
- The meta suite runs in the repository's test sandbox: no git repository variable, a throwaway
  home and git config, and a run that changes the checkout it runs from fails.
- `write-a-skill` gives a user-invoked skill's eval a grader on a call the skill makes, not on
  the Skill tool: a typed `/plugin:name` command loads the skill without that call, so the
  Skill-tool grader could never pass.

## 1.1.5 (2026-11-08)

- `retro` reads the lessons whose time is after the last retro's time, not a line count, and
  writes the run's UTC time in the `retros.log` line. The log can be rewritten under it.

## 1.1.4 (2026-11-03)

- `retro` says the lessons log stays on this machine under `.flow/` and is never committed, as
  the flow's retro job no longer commits it.

## 1.1.3 (2026-11-01)

- `retro`: a marketplace PR adds a changelog fragment per plugin it changes,
  `plugins/<plugin>/changelog.d/retro-<date>.md`, and never edits the version or `CHANGELOG.md`.
  The release PR folds the fragments (ADR 0002 in the marketplace).
