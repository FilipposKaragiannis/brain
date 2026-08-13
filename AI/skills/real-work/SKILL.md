---
name: real-work
description: Use when planning or executing multi-step work that needs a durable, resumable plan with phased checklists, autonomous verification, mandatory user review of each phase's changed files, and an explicit choice between committing locally or opening a PR. Use when the user asks to create or execute a plan, works in plan mode, or mentions "real work".
---

# Real Work

Turn planning into a durable, resumable artifact. The plan file — not the
conversation — is the source of truth: it records what to do, what's done, how it
was verified, and how to deploy. Any future agent can resume from it with zero
prior context.

Every phase ends at a **review gate**: the user reviews the updated files before
the phase becomes complete, then separately chooses whether to commit them to the
local plan branch or branch off and open a PR.

## 1. Reach complete understanding first

Do **not** write the plan until scope is fully understood. Relentlessly ask the
user questions until you both share a complete understanding with **no gaps** —
treat an unasked question as a future bug.

- Don't stop at the first round; keep going until no ambiguity, assumption, or
  open decision remains. Probe edges: scope boundaries (in/out), dependencies,
  constraints, success criteria, data, environments, deployment, failure cases.
- Surface every assumption for the user to confirm. If an answer opens a new
  unknown, ask the follow-up — drill down recursively.
- Use `AskUserQuestion` for concrete choices. When done, summarize the full scope
  back and only proceed once the user confirms nothing is missing.

## 2. Write the plan

Save to `plans/<descriptive-name>.md` in the **repository root** (create `plans/`
if needed).

Work from a local **plan branch**. Reuse the current branch only when it is a
non-default branch already dedicated to this plan; otherwise create
`plan/<descriptive-name>` from the current `HEAD`. Record the plan branch and its
base in the plan. If the worktree was already dirty, record the pre-existing
changes and keep them outside every phase's review and commit scope.

Use this self-documenting template:

```markdown
# <Work Title>

<1-2 sentence goal and scope.>

## For Future Agents
Plan branch: `<branch>`
Base branch: `<branch>`

As work proceeds: mark checkboxes `- [x]` as items complete. When a phase's
implementation is done, run its **Verification Plan**, record the result, write
its **Phase Summary**, and set the status to `Awaiting review`. Show the user
every file changed by that phase and wait for approval. After approval, ask
whether to commit on the local plan branch or create a phase branch and PR. Set
the phase to `Complete` only as part of the selected delivery. Update living
documentation alongside behaviour or structure changes. When all phases are
done, fill in **Final Recap** and **Deployment Plan**.

## Phase 1: <Title>
Status: Not started   <!-- Not started | In progress | Awaiting review | Complete -->

- [ ] <concrete, actionable item>
- [ ] <concrete, actionable item>

### Verification Plan
- <command/check the agent can run autonomously, with expected result>

### Phase Summary
_(write before requesting phase review; include verification results)_

## Phase 2: <Title>
Status: Not started   <!-- Not started | In progress | Awaiting review | Complete -->
- [ ] <actionable item>
### Verification Plan
- <autonomous check>
### Phase Summary
_(write before requesting phase review; include verification results)_

## Final Recap
_(write when all phases complete: summary of the entire piece of work)_

## Deployment Plan
_(write when all phases complete: step-by-step deployment instructions)_
```

## 3. Gate every phase through review and delivery

Complete each phase in this order:

1. Finish its checked work, update any living documentation, run the autonomous
   verification, and record the results in the Phase Summary.
2. Set the phase status to `Awaiting review`. Identify the exact files changed
   by this phase relative to its starting state; exclude unrelated pre-existing
   changes.
3. Present the changed-file list with clickable paths and a concise diff and
   verification summary. Ask the user to review the updated files and approve or
   request changes. **Pause here.** Apply requested changes and repeat this gate
   until the user approves.
4. After approval, ask a separate delivery question and **pause again**:
   - **Commit locally** — mark the phase `Complete` and commit only the phase's
     files plus the plan file on the local plan branch. Do not push.
   - **Open a PR** — create a `phase/<plan>-<phase>` branch from the plan branch,
     mark the phase `Complete`, commit only the phase's files plus the plan file,
     push that branch, and open a PR against the plan's recorded base branch.
     The PR is cumulative: it contains plan-branch work through this phase. Do
     not merge it without a separate user request.
5. Record the delivery mode and branch in the Phase Summary before committing.
   After delivery, report the commit SHA or PR URL to the user. Begin the next
   phase only after the selected delivery is complete.

Review approval authorizes neither delivery path. The user's answer to the
separate delivery question authorizes only the path they selected.

## Common mistakes

- **Vague items** — each checkbox is a concrete task ("Add retry logic to
  `PaymentClient.Charge`"), not a theme ("improve payments").
- **Non-autonomous verification** — give runnable commands with expected output,
  not "test it manually".
- **Wrong location** — always the repo-root `plans/` folder.
- **Pre-filling summaries** — a Phase Summary stays a placeholder until that
  phase's work and verification finish; the recap and deployment plan stay
  placeholders until all work finishes.
- **Completing before review** — `Awaiting review` is a hard gate; user approval
  comes before `Complete`.
- **Conflating approvals** — approval of the files is not permission to commit,
  push, or open a PR. Ask the delivery question separately.
