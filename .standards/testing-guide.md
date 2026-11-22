# Testing guide

Written once by `standards:init` from the build files; the owner edits it. The verifier and
the test writer read it. Rules T-01 to T-13 in `.standards/rules/07-tests.md` apply everywhere;
this file holds only what is specific to this repository.

## Levels and commands

| level | when | command |
|---|---|---|
| unit | in verify, the parts a change can affect | `test` in `.standards/config.json`: one `tools/test.sh <part>` per suite (standards, flow, meta, console, console-app, tools, plugins), each with the paths it reads, and for flow `tools/test.sh flow-since {verify_base}`, which picks the Flow suites; `tools/test.sh` alone runs every part, as CI and a person do |
| integration | a boundary is crossed (I/O, network, process, engine) | no separate run: the shell suites above cross those boundaries through stub tools; the console app: `cd plugins/console/app && npm run check` |
| regression | every bug fix, named after the bug | part of the unit run |
| mutation | on PRs for changed files, full on a schedule; a signal, never a gate | none: `mutation` is empty in `.standards/config.json` |

## One test or one group

The implement, test and comments steps run only the tests they touched. The whole of a suite
runs once, in verify, and a suite that passed on the same files is not run again.

- One Flow suite alone: `sh plugins/flow/tests/<file>.sh`, such as `holds.sh`, `pick.sh` or `jobs.sh`; one adapter's contract: `sh plugins/flow/tests/adapter-contract.sh <github|local|jira>`. Every Flow check lives in a suite file, one per area.
- A new Flow test goes in a sandboxed suite file of its own on `_base_fixture.sh`. The suite files cut from the old `run.sh` source `_flow_setup.sh` and the `_` fixtures that hold the helpers they share. The runner discovers `tests/*.sh` automatically. Prefix a fixture with `_` or `fake-`.
- Verify selects the Flow suites from the paths changed since the verifier's merge base: an edit to one suite file selects that suite, `adapter-contract.sh` the three contracts, `_verify_fixture.sh` the `verify-*` suites, and the verifier command and its report and check helpers the `verify-*` suites with `verify-report.sh`, `base-claim.sh` and `base-readers.sh`. A changelog or README edit selects none. Any other path under the flow entry's `paths`, `_base_fixture.sh` included, and a base that cannot be resolved run every suite. A full run is every suite file and all three adapter contracts.
- The runner, `tools/lib/flow_suites.py`, runs the chosen suites in lanes, three at once unless `FLOW_SUITE_LANES` says otherwise, each in a sandbox of its own. A suite still running after 30 minutes (`FLOW_SUITE_TIME_LIMIT_SECONDS`) is stopped, its output so far printed, and the run fails naming it.
- CI and `tools/test.sh flow` use the full run. `plugins/flow/tests/run.sh` holds no checks: with no argument it hands the full run to the runner, and any argument is a usage error. The existing `whole-suite` gate covers `plugins/flow/tests/run.sh` and `tools/test.sh` during implement, test and comments. Run individual suite files there. A local full run needs the owner's `[whole-suite]` approval.
- One console daemon test file: `cd plugins/console/app && sh ../../../tools/lib/sandboxed.sh . node --test daemon/test/<file>.test.ts`.
- One console UI test file: `cd plugins/console/app/ui && npx vitest run test/<file>`.
- The other shell suites take minutes, and each file runs alone; a `run.sh` among them has no filter. Standards: `plugins/standards/hooks/tests/run.sh`, `file-names.sh`, `files-placeholder.sh`, `testing-guide.sh`, `appendices.sh`. Tools: `tools/tests/run.sh`, `lint-baseline.sh`, `flow-selection.sh`, `flow-runner.sh`, `suite-parity.sh`. Meta and console: `plugins/meta/tests/run.sh`, `plugins/console/tests/run.sh`.
- Lint, `tools/lint.sh` (the `build` command), runs ShellCheck and Ruff on the shell and Python files and fails on a finding the baseline in `tools/lint-baseline/` does not hold. After a change that fixes recorded findings, or one the owner accepts, `python3 -I tools/lib/lint_baseline.py update` rewrites the baseline.

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
