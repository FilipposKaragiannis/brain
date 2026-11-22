# Testing guide

Written once by `standards:init` from the build files; the owner edits it. The verifier and
the test writer read it. Rules T-01 to T-13 in `.standards/rules/07-tests.md` apply everywhere;
this file holds only what is specific to this repository.

## Levels and commands

| level | when | command |
|---|---|---|
| unit | in verify, the parts a change can affect | `test` in `.standards/config.json`: one `tools/test.sh <part>` per suite (standards, flow, meta, console, console-app, tools, plugins), each with the paths it reads; `tools/test.sh` alone runs every part, as CI and a person do |
| integration | a boundary is crossed (I/O, network, process, engine) | no separate run: the shell suites above cross those boundaries through stub tools; the console app: `cd plugins/console/app && npm run check` |
| regression | every bug fix, named after the bug | part of the unit run |
| mutation | on PRs for changed files, full on a schedule; a signal, never a gate | none: `mutation` is empty in `.standards/config.json` |

## One test or one group

The implement, test and comments steps run only the tests they touched. The whole of a suite
runs once, in verify, and a suite that passed on the same files is not run again.

- A flow test in a suite file of its own, alone: `sh plugins/flow/tests/<file>.sh` (`holds.sh`, `blockers.sh`, `base-claim.sh`, `base-readers.sh`, `verify-detached.sh`, `verify-ends.sh`, `verify-scope.sh`; `adapter-contract.sh <adapter>`). Each takes one to four minutes. The 16 files cut from the old `run.sh`, one per area such as `pick.sh` or `init.sh`, take under four minutes each, except `jobs.sh` and `health.sh`, which take about seven and nine minutes.
- A new Flow test goes in a sandboxed suite file of its own on `_base_fixture.sh`. The suite files cut from the old `run.sh` source `_flow_setup.sh` and the `_` fixtures that hold the helpers they share. The runner discovers `tests/*.sh` automatically. Prefix a fixture with `_` or `fake-`.
- Brain's verify compares the item with the verifier's merge base. An edit to one standalone suite selects that suite. Changes to the verifier command or its report and cache helpers select `verify-report.sh` and the other suites that exercise verify. Shared runtime changes and unavailable comparison bases run the complete Flow suite. A full run includes every suite file and all three adapter contracts, with at most three suites running at once.
- CI and `tools/test.sh flow` use the full run. `plugins/flow/tests/run.sh` holds no checks: with no argument it hands the full run to the runner, and any argument is a usage error. The existing `whole-suite` gate covers `plugins/flow/tests/run.sh` and `tools/test.sh` during implement, test and comments. Run individual suite files there. A local full run needs the owner's `[whole-suite]` approval.
- One console daemon test file: `cd plugins/console/app && sh ../../../tools/lib/sandboxed.sh . node --test daemon/test/<file>.test.ts`.
- One console UI test file: `cd plugins/console/app/ui && npx vitest run test/<file>`.
- The standards, meta, console and tools shell suites have no filter and take minutes, not an hour: `plugins/standards/hooks/tests/run.sh`, `plugins/meta/tests/run.sh`, `plugins/console/tests/run.sh`, `tools/tests/run.sh`.

## Fixtures and helpers

- Where fixtures live and how to add one: repo tools in `tools/tests/fixtures/` (e.g. `broken/`, `release/demo/`); console daemon in `plugins/console/app/daemon/test/fixtures/` (e.g. `project/.flow/`, `gh/`), resolved through `FIXTURES` in `daemon/test/fakeRunner.ts`. Add a folder there and point the test at it.
- Builders and fakes the tests share: daemon `fakeRunner.ts`, `fakeSpawner.ts`, `fakeSubagents.ts` (plugins/console/app/daemon/test/); UI `fakeDaemon.tsx` (plugins/console/app/ui/test/); a fake gh and a fake jira in `plugins/flow/tests/fake-gh.sh` and `fake-jira.sh` (also reached by the evals through `tools/eval-bin/`); the shell suites put stubs for curl, wget, gh, osascript, notify-send, claude and codex first in PATH.
- Time, randomness and I/O are injected (S-11); the fakes for them: the daemon takes a `clock` and a `Scheduler` (`realScheduler` in src/actions.ts; `fakeScheduler()` in daemon/test/fakeSpawner.ts) and runs commands through `CommandRunner`/`Spawner` (fakeRunner.ts, fakeSpawner.ts); UI tests use `vi.useFakeTimers()`; shell suites run under `env -i` with stub tools in PATH. Randomness: none injected.

## Declared exceptions

Tests that the rules would reject but the project keeps on purpose, each with the reason:

- _none yet_ (example: golden-file tests for the renderer, because a pixel diff is the spec)

## What the owner tests by hand

The feel-test list the verifier raises a gate for (`feel_test_paths` in `.flow/config.yaml`):

- Console UI (plugins/console/app/ui/**): run `plugins/console/scripts/demo.sh` from the repo root (demo only, never a real project), open port 7478 with the token from `$TMPDIR/brain-console-demo/state/token`; check each gate shows its waiting item, answer one, start the ready item and see its stub-agent calls in `agents.log`; Ctrl+C and leave no daemon running.
