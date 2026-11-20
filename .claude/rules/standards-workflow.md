---
paths:
  - "**/*.sh"
---
# 8. Commits, PRs and behaviour

- **W-01 Conventional commits, short bodies.** [hard] `type(scope): summary`, then a body of a few short lines that says what changed and why. No essays. *Why:* a long commit message is not read.
- **W-02 One concern per PR.** [hard] *Why:* a mixed PR cannot be reviewed or reverted cleanly.
- **W-03 PR size is a signal.** [signal] Around 400 changed lines means it should have been two PRs.
- **W-04 Minimal diff.** [hard] Change only what the task needs. No renames or refactors outside the agreed scope, no error handling for impossible cases. A second post-hoc refactor of the same code means the design is wrong: stop and replan. *Why:* every extra line is review cost and risk with no value to the task.
- **W-05 Review severity.** [hard] A broken hard rule blocks. A crossed signal with no explanation blocks. A judgement disagreement is a comment. Specialised review agents enforce this. *Why:* the reviewer must never have to decide how serious a finding is.
- **W-06 Learning loop.** [hard] A decision goes to an ADR, a new word to the glossary, a new rule to this file. Only the owner approves a change to this file, and a rule meant to apply everywhere also changes the plugin that enforces it. *Why:* a rule that lives only in one project's docs is not a rule.
- **W-07 Reporting.** [hard] Report the result once, at the end: what changed, what the owner must test by hand, and what is next. During long work a one-line note on the current step is welcome; never paste compilation logs. On a failure the order is the error text, then the cause, then the fix attempted. *Why:* the owner decides from one message, and a short note during long work tells them the agent is still on track.
- **W-08 Ambiguity: ask, unless current practice already answers it.** [judgement] When a spec is ambiguous and the codebase shows an established way, follow it and state the assumption. Otherwise stop and ask. *Why:* a wrong guess costs more than a question; a question about something the code already answers costs the owner's time.
