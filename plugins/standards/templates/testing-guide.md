# Testing guide

Written once by `standards:init` from the build files; the owner edits it. The verifier and
the test writer read it. Rules T-01 to T-13 in `.standards/rules/07-tests.md` apply everywhere;
this file holds only what is specific to this repository.

## Levels and commands

Each row names the slot that runs it:

- test command: `test` in `.standards/config.json`; the flow verifier runs it on every verify.
- mutation command: `mutation` in `.standards/config.json`; the verifier runs it as a signal.
- verify gate: an entry under `gates` in `.flow/config.yaml`; the verifier runs it after the tests.
- commit gate: an entry in `gates[]` in `.standards/config.json`, with `when` set to `commit`,
  `push` or `ci`; the git hooks or the CI action run it.
- scheduled check: an entry under `jobs.checks` in `.flow/config.yaml`; the flow's check job runs
  it on its schedule from a clean checkout of the base. A CI workflow with an `on: schedule`
  trigger works too.
- nothing: no slot runs it, so it runs only when an agent or the owner starts it by hand.

A row whose command is `not set up` is a check the project does not have yet.

| level | when | slot | command |
|---|---|---|---|
| unit | every change | test command | `{{test}}` |
| integration | a boundary is crossed (I/O, network, process, engine) | test command when it includes these tests, otherwise nothing | `{{test}} --filter Category=Integration` |
| regression | every bug fix, named after the bug | test command | part of the unit run |
| mutation | on PRs for changed files, full on a schedule; a signal, never a gate | mutation command; the full run a scheduled check | `{{mutation}}` |
| smoke | a change reaches startup, wiring or packaging: the app starts and answers its first request or screen | nothing | not set up |
| property-based | a change to logic with invariants over many inputs (parsers, serializers, math, state machines) | nothing | not set up |
| runtime evidence | a change to behaviour only the running app shows (logs, a screen, a live endpoint, a performance budget) | nothing | not set up |

## One test or one group

The implement and test steps run only the tests they touched; the whole test command runs once,
in verify, scoped to the change (`build` and `test` in `.standards/config.json` take `paths`).

- The command that runs one test, one file or one group alone: _fill in_ (example: `dotnet test --filter FullyQualifiedName~BallSpin`).

## Fixtures and helpers

- Where fixtures live and how to add one: _fill in_.
- Builders and fakes the tests share: _fill in_.
- Time, randomness and I/O are injected (S-11); the fakes for them: _fill in_.

## Declared exceptions

Tests that the rules would reject but the project keeps on purpose, each with the reason:

- _none yet_ (example: golden-file tests for the renderer, because a pixel diff is the spec)

## What the owner tests by hand

The feel-test list the verifier raises a gate for (`feel_test_paths` in `.flow/config.yaml`):

- _fill in: what to launch, what to look for_
