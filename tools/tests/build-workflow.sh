#!/bin/sh
# Tests that the CI workflow limits every job, gathers them under one result and skips no part,
# and that every job that runs lint, in CI or in the release workflow, installs the linters first.
# Ruby reads the workflow because python3 has no YAML module here or in CI.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
. "$root/tools/lib/sandbox.sh"; sandbox_enter "$work" "$root/tools"
trap 'sandbox_close $?' EXIT

expect() { [ "$2" = "$3" ] || { echo "FAIL $1"; echo "  got:      $2"; echo "  expected: $3"; exit 1; }; echo "ok $1"; }
yaml_to_json() {
  ruby -ryaml -rjson -e 'File.write(ARGV[1], JSON.generate(YAML.safe_load(File.read(ARGV[0]))))' "$1" "$2" 2> "$work/ruby-errors" \
    || { echo "FAIL $1 could not be read as YAML"; cat "$work/ruby-errors"; exit 1; }
}
json_to_yaml() {
  ruby -ryaml -rjson -e 'File.write(ARGV[1], YAML.dump(JSON.parse(File.read(ARGV[0]))))' "$1" "$2" 2> "$work/ruby-errors" \
    || { echo "FAIL $1 could not be written as YAML"; cat "$work/ruby-errors"; exit 1; }
}
cat > "$work/shape.py" <<'PY'
import json
import re
import shlex
import sys
from itertools import takewhile

_TEST_SCRIPT = "tools/test.sh"
_LINT_SCRIPT = "tools/lint.sh"
_LINT_PART = "lint"
_LINTER_REQUIREMENTS = "tools/requirements-lint.txt"
_PART_NAME = re.compile(r"[a-z][a-z-]*")
_NEW_JOB = {"runs-on": "ubuntu-latest", "timeout-minutes": 5, "steps": [{"run": "true"}]}


def _runs(workflow: dict) -> "list[str]":
    return [step["run"] for job in workflow["jobs"].values() for step in job.get("steps", []) if "run" in step]


def _parts_after(words: "list[str]") -> "list[str]":
    return list(takewhile(_PART_NAME.fullmatch, words))


def _part_lists(workflow: dict) -> "list[list[str]]":
    commands = [shlex.split(run) for run in _runs(workflow)]
    return [_parts_after(words[at + 1:]) for words in commands for at, word in enumerate(words) if word == _TEST_SCRIPT]


def _listed(needs: "str | list[str]") -> "set[str]":
    return {needs} if isinstance(needs, str) else set(needs)


def without_time_limit(workflow: dict) -> "list[str]":
    return sorted(name for name, job in workflow["jobs"].items() if not isinstance(job.get("timeout-minutes"), int))


def missing_from_result_needs(workflow: dict) -> "list[str]":
    return sorted(set(workflow["jobs"]) - {"result"} - _listed(workflow["jobs"]["result"].get("needs", [])))


def named_parts(workflow: dict) -> "list[str]":
    return sorted({part for parts in _part_lists(workflow) for part in parts})


def bare_test_script_runs(workflow: dict) -> "list[str]":
    return [str(sum(1 for parts in _part_lists(workflow) if not parts))]


def result_script(workflow: dict) -> "list[str]":
    return [step["run"] for step in workflow["jobs"]["result"]["steps"] if "run" in step]


def skip_guard(workflow: dict) -> "list[str]":
    return [step["run"] for step in workflow["jobs"]["console"]["steps"] if "grep -i skip" in step.get("run", "")]


def _runs_lint(run: str) -> bool:
    words = shlex.split(run)
    parts = [part for at, word in enumerate(words) if word == _TEST_SCRIPT for part in _parts_after(words[at + 1:])]
    return _LINT_SCRIPT in words or _LINT_PART in parts


def _lints_before_installing(job: dict) -> bool:
    runs = [step["run"] for step in job.get("steps", []) if "run" in step]
    before_lint = list(takewhile(lambda run: not _runs_lint(run), runs))
    return len(before_lint) < len(runs) and not any(_LINTER_REQUIREMENTS in shlex.split(run) for run in before_lint)


def lint_without_linters(workflow: dict) -> "list[str]":
    return sorted(name for name, job in workflow["jobs"].items() if _lints_before_installing(job))


def without_linter_install(workflow: dict, job: str) -> dict:
    steps = [step for step in workflow["jobs"][job]["steps"] if _LINTER_REQUIREMENTS not in step.get("run", "")]
    return dict(workflow, jobs=dict(workflow["jobs"], **{job: dict(workflow["jobs"][job], steps=steps)}))


def without_need(workflow: dict, job: str) -> dict:
    result = dict(workflow["jobs"]["result"], needs=[need for need in workflow["jobs"]["result"]["needs"] if need != job])
    return dict(workflow, jobs=dict(workflow["jobs"], result=result))


def with_job(workflow: dict, job: str) -> dict:
    return dict(workflow, jobs=dict(workflow["jobs"], **{job: _NEW_JOB}))


_QUESTIONS = {
    "without-time-limit": without_time_limit,
    "missing-from-result-needs": missing_from_result_needs,
    "named-parts": named_parts,
    "bare-test-script-runs": bare_test_script_runs,
    "result-script": result_script,
    "skip-guard": skip_guard,
    "lint-without-linters": lint_without_linters,
}
_EDITS = {"without-need": without_need, "with-job": with_job, "without-linter-install": without_linter_install}


def main(arguments: "list[str]") -> int:
    with open(arguments[1], encoding="utf-8") as source:
        workflow = json.load(source)
    if arguments[0] == "ask":
        print(" ".join(_QUESTIONS[arguments[2]](workflow)))
        return 0
    with open(arguments[3], "w", encoding="utf-8") as target:
        json.dump(_EDITS[arguments[0]](workflow, arguments[2]), target)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
PY
ask() { python3 -I "$work/shape.py" ask "$@"; }
edit() { python3 -I "$work/shape.py" "$@"; }

workflow="$work/workflow.json"
yaml_to_json "$root/.github/workflows/ci.yml" "$workflow"
every_part="$("$root/tools/test.sh" no-such-part 2>&1 | sed -n 's/^.* the parts are //p')"
parts_run_by_shards="$(printf '%s\n' "$every_part" | tr ' ' '\n' | grep -vx flow | sort | tr '\n' ' ' | sed 's/ $//')"

needs_check_on() {
  json_to_yaml "$1" "$work/rewritten.yml"; yaml_to_json "$work/rewritten.yml" "$work/rewritten.json"
  ask "$work/rewritten.json" missing-from-result-needs
}
edit without-need "$workflow" flow "$work/without-flow.json"
edit with-job "$workflow" new-job "$work/with-new-job.json"
release_workflow="$work/release.json"
yaml_to_json "$root/.github/workflows/release.yml" "$release_workflow"
edit without-linter-install "$release_workflow" release "$work/release-without-linters.json"

ask "$workflow" result-script > "$work/result.sh"
result_for() {
  needs="{\"lint\":{\"result\":\"success\"},\"flow\":{\"result\":\"$1\"}}"
  if RESULTS="$needs" sh "$work/result.sh" > "$work/output" 2>&1; then echo pass; else echo fail; fi
}
ask "$workflow" skip-guard > "$work/skip-guard.sh"
skip_guard_for() {
  printf '%s\n' "$1" > "$work/console.log"
  if RUNNER_TEMP="$work" sh "$work/skip-guard.sh" > "$work/output" 2>&1; then echo pass; else echo fail; fi
}

expect 'EveryJob_HasATimeLimit because a hung suite once ran 73 minutes' "$(ask "$workflow" without-time-limit)" ''
expect 'ResultJob_NeedsEveryOtherJob because one required check must stand for them all' "$(ask "$workflow" missing-from-result-needs)" ''
expect 'ResultJobMissingANeed_FailsTheNeedsCheck because a job left out of needs would not hold up the required check' "$(needs_check_on "$work/without-flow.json")" flow
expect 'JobAddedWithoutANeed_FailsTheNeedsCheck because a job added later must join the required check' "$(needs_check_on "$work/with-new-job.json")" new-job
expect 'ReformattedWorkflow_PassesTheNeedsCheck because layout is not behaviour' "$(needs_check_on "$workflow")" ''
expect 'ResultStepGivenOnlySuccess_Passes because every job holds' "$(result_for success)" pass
expect 'ResultStepGivenAFailure_Fails because one failed job fails the run' "$(result_for failure)" fail
expect 'ResultStepGivenASkippedJob_Fails because a job that did not run proves nothing' "$(result_for skipped)" fail
expect 'ResultStepGivenACancelledJob_Fails because a job that did not finish proves nothing' "$(result_for cancelled)" fail
expect 'ResultStep_NamesEachJobWithItsResult because the owner must see which job broke' "$(result_for failure >/dev/null; grep -c 'flow.*failure' "$work/output")" 1
expect 'EveryPartButFlow_IsNamedOnTheTestScriptCommandLine because an unnamed part is skipped when its tools are missing' "$(ask "$workflow" named-parts)" "$parts_run_by_shards"
expect 'TestScriptWithNoPartNamed_IsNeverRun because a whole run skips a part whose tools are missing' "$(ask "$workflow" bare-test-script-runs)" 0
expect 'ConsoleLogWithASkippedCheck_FailsTheJob because a check that did not run proves nothing' "$(skip_guard_for '  skip a demo pane: no zsh on PATH')" fail
expect 'ConsoleLogWithEveryCheckRun_PassesTheJob because nothing was left out' "$(skip_guard_for '  ok every check')" pass
expect 'CiJobThatRunsLint_InstallsTheLintersFirst because lint fails in CI when a linter is missing' "$(ask "$workflow" lint-without-linters)" ''
expect 'ReleaseJobThatRunsLint_InstallsTheLintersFirst because a release that cannot lint opens no release PR' "$(ask "$release_workflow" lint-without-linters)" ''
expect 'ReleaseJobWithoutTheLinterInstall_FailsTheLinterCheck because the check must see a job that lints with no linters' "$(ask "$work/release-without-linters.json" lint-without-linters)" release
