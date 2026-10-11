# Testing guide

Written once by `standards:init` from the build files; the owner edits it. The verifier and
the test writer read it. Rules T-01 to T-13 in `.standards/rules/07-tests.md` apply everywhere;
this file holds only what is specific to this repository.

## Levels and commands

| level | when | command |
|---|---|---|
| unit | every change | `{{test}}` |
| integration | a boundary is crossed (I/O, network, process, engine) | `{{test}} --filter Category=Integration` |
| regression | every bug fix, named after the bug | part of the unit run |
| mutation | on PRs for changed files, full on a schedule; a signal, never a gate | `{{mutation}}` |

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
