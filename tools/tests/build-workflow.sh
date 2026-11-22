#!/bin/sh
# Tests that the CI workflow limits every job, gathers them under one result and skips no part,
# and that a job that runs lint, in CI or in the release workflow, has installed the linters by then.
# The lint checks run the job's own steps here, with stand-ins for pip, lint and the release script.
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
}
_EDITS = {"without-need": without_need, "with-job": with_job}


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
cat > "$work/run_job.py" <<'PY'
import json
import os
import subprocess
import sys
from pathlib import Path

_STEP_LIMIT_SECONDS = 60
_CONDITIONS_THAT_HOLD = ("true", "always()", "success()")
_SHELL = ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c"]
_NO_LINT = "lint did not run"


def _runs_here(step: dict) -> bool:
    return "run" in step and str(step.get("if", "true")).strip().lower() in _CONDITIONS_THAT_HOLD


def _passes(step: dict, checkout: Path, environment: "dict[str, str]") -> bool:
    try:
        return subprocess.run([*_SHELL, step["run"]], cwd=checkout, env=environment, capture_output=True, timeout=_STEP_LIMIT_SECONDS, check=False).returncode == 0
    except subprocess.TimeoutExpired:
        return False


def lint_outcome(job: dict, checkout: Path, outcome: Path, environment: "dict[str, str]") -> str:
    for step in filter(_runs_here, job.get("steps", [])):
        if not _passes(step, checkout, environment) or outcome.exists():
            break
    return outcome.read_text(encoding="utf-8").strip() if outcome.exists() else _NO_LINT


def main(arguments: "list[str]") -> int:
    workflow, job, checkout, outcome, stand_ins = arguments
    with open(workflow, encoding="utf-8") as source:
        jobs = json.load(source)["jobs"]
    environment = dict(os.environ, PATH=stand_ins + os.pathsep + os.environ["PATH"])
    print(lint_outcome(jobs[job], Path(checkout), Path(outcome), environment))
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

stand_ins="$work/stand-ins"; runner_files="$work/runner-files"
mkdir "$stand_ins" "$runner_files"
cat > "$stand_ins/pip" <<'STUB'
#!/bin/sh
[ "${1:-}" = install ] || exit 0
shift
requirements=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -r|--requirement) requirements="${2:-}" ;;
    --requirement=*) requirements="${1#--requirement=}" ;;
    -r*) requirements="${1#-r}" ;;
  esac
  shift
done
[ -n "$requirements" ] && cmp -s "$requirements" tools/requirements-lint.txt || exit 0
: > "$LINTERS_INSTALLED"
STUB
cat > "$stand_ins/python" <<'STUB'
#!/bin/sh
[ "${1:-}" = -m ] && [ "${2:-}" = pip ] || exit 0
shift 2
exec pip "$@"
STUB
cp "$stand_ins/python" "$stand_ins/python3"
chmod +x "$stand_ins/pip" "$stand_ins/python" "$stand_ins/python3"
lint_outcome_of() {
  rm -rf "$work/checkout" "$work/lint-outcome" "$work/linters-installed"
  mkdir -p "$work/checkout/tools"
  cp "$root/tools/requirements-lint.txt" "$work/checkout/tools/requirements-lint.txt"
  printf '%s\n' '#!/bin/sh' 'if [ -f "$LINTERS_INSTALLED" ]; then echo "linted with the linters" > "$LINT_OUTCOME"; exit 0; fi' 'echo "linted without the linters" > "$LINT_OUTCOME"; exit 1' > "$work/checkout/tools/lint.sh"
  printf '%s\n' '#!/bin/sh' 'for part in "$@"; do [ "$part" != lint ] || exec tools/lint.sh; done' > "$work/checkout/tools/test.sh"
  printf '%s\n' '#!/bin/sh' 'echo "flow 1.0.0 -> 1.1.0"' > "$work/checkout/tools/release.sh"
  chmod +x "$work/checkout/tools/lint.sh" "$work/checkout/tools/test.sh" "$work/checkout/tools/release.sh"
  CI=true LINT_OUTCOME="$work/lint-outcome" LINTERS_INSTALLED="$work/linters-installed" \
    RUNNER_TEMP="$runner_files" GITHUB_OUTPUT="$runner_files/output" GITHUB_ENV="$runner_files/environment" \
    python3 -I "$work/run_job.py" "$1" "$2" "$work/checkout" "$work/lint-outcome" "$stand_ins"
}
cat > "$work/job_of_steps.py" <<'PY'
import json
import sys

_SWITCHED_OFF = "switched-off:"


def _step(run: str) -> dict:
    return {"if": False, "run": run[len(_SWITCHED_OFF):]} if run.startswith(_SWITCHED_OFF) else {"run": run}


with open(sys.argv[1], "w", encoding="utf-8") as target:
    json.dump({"jobs": {"job": {"steps": [_step(run) for run in sys.argv[2:]]}}}, target)
PY
job_with_steps() { python3 -I "$work/job_of_steps.py" "$work/job.json" "$@"; lint_outcome_of "$work/job.json" job; }
install='python -m pip install -r tools/requirements-lint.txt'

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
expect 'ContinuousIntegrationLintJob_LintsWithTheLinters because lint fails there when a linter is missing' "$(lint_outcome_of "$workflow" lint)" 'linted with the linters'
expect 'ReleaseJob_LintsWithTheLinters because a release that cannot lint opens no release pull request' "$(lint_outcome_of "$release_workflow" release)" 'linted with the linters'
expect 'JobThatLintsWithNoInstall_LintsWithoutTheLinters because the check must see a job that never installs them' "$(job_with_steps 'tools/lint.sh')" 'linted without the linters'
expect 'JobThatRunsTheLintPartWithNoInstall_LintsWithoutTheLinters because the lint part runs the same lint' "$(job_with_steps 'tools/test.sh tools lint')" 'linted without the linters'
expect 'JobThatOnlyNamesTheRequirementsFile_LintsWithoutTheLinters because naming the file installs nothing' "$(job_with_steps 'echo tools/requirements-lint.txt' 'tools/lint.sh')" 'linted without the linters'
expect 'JobThatLintsThenInstalls_LintsWithoutTheLinters because lint ran before its linters were there' "$(job_with_steps "tools/lint.sh; $install")" 'linted without the linters'
expect 'JobWhoseInstallStepIsSwitchedOff_LintsWithoutTheLinters because a step that does not run installs nothing' "$(job_with_steps "switched-off:$install" 'tools/lint.sh')" 'linted without the linters'
expect 'JobThatInstallsAndLintsInOneStep_LintsWithTheLinters because the order of the commands is what counts' "$(job_with_steps "$(printf '# the pinned linters\n%s\ntools/lint.sh' "$install")")" 'linted with the linters'
expect 'JobThatPrintsTheLintScriptNameBeforeItsInstall_LintsWithTheLinters because printing a name runs nothing' "$(job_with_steps 'echo tools/lint.sh' "$install && ./tools/lint.sh")" 'linted with the linters'
expect 'JobThatInstallsWithTheLongOption_LintsWithTheLinters because pip takes a requirements file in this form too' "$(job_with_steps 'pip install --requirement=./tools/requirements-lint.txt' 'tools/test.sh lint')" 'linted with the linters'
expect 'JobThatNeverLints_SaysLintDidNotRun because a job with no lint needs no linters' "$(job_with_steps 'true')" 'lint did not run'
