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
from itertools import groupby, takewhile

_TEST_SCRIPT = "tools/test.sh"
_LINT_SCRIPT = "tools/lint.sh"
_LINT_PART = "lint"
_LINTER_REQUIREMENTS = "tools/requirements-lint.txt"
_INSTALL_COMMAND = "install"
_REQUIREMENTS_OPTIONS = ("-r", "--requirement")
_REQUIREMENTS_OPTIONS_JOINED_TO_THE_FILE = ("-r", "--requirement=")
_PART_NAME = re.compile(r"[a-z][a-z-]*")
_COMMAND_SEPARATOR = re.compile(r"[;&|()]+")
_LINE_CONTINUATION = "\\\n"
_LINE_END = "\n"
_SEPARATOR_AFTER_A_LINE_END = "\n;\n"
_HASH_INSIDE_A_WORD = re.compile(r"(?<=[^\s;&|()])#")
_ESCAPED_HASH = r"\#"
_NEW_JOB = {"runs-on": "ubuntu-latest", "timeout-minutes": 5, "steps": [{"run": "true"}]}


def _runs(workflow: dict) -> "list[str]":
    return [step["run"] for job in workflow["jobs"].values() for step in job.get("steps", []) if "run" in step]


def _names(word: str, path: str) -> bool:
    return word == path or word.endswith("/" + path)


def _parts_after(words: "list[str]") -> "list[str]":
    return list(takewhile(_PART_NAME.fullmatch, words))


def _commands(run: str) -> "list[list[str]]":
    joined = _HASH_INSIDE_A_WORD.sub(_ESCAPED_HASH, run.replace(_LINE_CONTINUATION, " "))
    lexer = shlex.shlex(joined.replace(_LINE_END, _SEPARATOR_AFTER_A_LINE_END), posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    grouped = groupby(lexer, key=lambda word: _COMMAND_SEPARATOR.fullmatch(word) is None)
    return [list(words) for is_command, words in grouped if is_command]


def _part_lists(workflow: dict) -> "list[list[str]]":
    commands = [words for run in _runs(workflow) for words in _commands(run)]
    return [_parts_after(words[at + 1:]) for words in commands for at, word in enumerate(words) if _names(word, _TEST_SCRIPT)]


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


def _commands_in_order(job: dict) -> "list[list[str]]":
    return [words for step in job.get("steps", []) if "run" in step for words in _commands(step["run"])]


def _runs_lint(words: "list[str]") -> bool:
    parts = [part for at, word in enumerate(words) if _names(word, _TEST_SCRIPT) for part in _parts_after(words[at + 1:])]
    return any(_names(word, _LINT_SCRIPT) for word in words) or _LINT_PART in parts


def _joined_requirements(word: str) -> bool:
    return any(word.startswith(option) and _names(word[len(option):], _LINTER_REQUIREMENTS) for option in _REQUIREMENTS_OPTIONS_JOINED_TO_THE_FILE)


def _names_linter_requirements(words: "list[str]", at: int) -> bool:
    return _joined_requirements(words[at]) or (words[at] in _REQUIREMENTS_OPTIONS and any(_names(word, _LINTER_REQUIREMENTS) for word in words[at + 1:at + 2]))


def _installs_linters(words: "list[str]") -> bool:
    named = [at for at in range(len(words)) if _names_linter_requirements(words, at)]
    return any(_INSTALL_COMMAND in words[:at] for at in named)


def _lints_before_installing(job: dict) -> bool:
    before_lint = list(takewhile(lambda words: not _runs_lint(words), _commands_in_order(job)))
    return len(before_lint) < len(_commands_in_order(job)) and not any(_installs_linters(words) for words in before_lint)


def lint_without_linters(workflow: dict) -> "list[str]":
    return sorted(name for name, job in workflow["jobs"].items() if _lints_before_installing(job))


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
job_running() { printf '{"jobs": {"release": {"steps": [%s]}}}' "$1" > "$work/job.json"; ask "$work/job.json" lint-without-linters; }

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
expect 'ContinuousIntegrationJobThatRunsLint_InstallsTheLintersFirst because lint fails there when a linter is missing' "$(ask "$workflow" lint-without-linters)" ''
expect 'ReleaseJobThatRunsLint_InstallsTheLintersFirst because a release that cannot lint opens no release pull request' "$(ask "$release_workflow" lint-without-linters)" ''
expect 'JobThatLintsWithNoInstall_FailsTheLinterCheck because the check must see a job that lints with no linters' "$(job_running '{"run": "tools/lint.sh"}')" release
expect 'JobThatOnlyNamesTheRequirementsFile_FailsTheLinterCheck because naming the file installs nothing' "$(job_running '{"run": "echo tools/requirements-lint.txt"}, {"run": "tools/lint.sh"}')" release
expect 'JobThatInstallsAndLintsInOneStep_PassesTheLinterCheck because the order of the commands is what counts' "$(job_running '{"run": "python -m pip install -r tools/requirements-lint.txt\ntools/lint.sh"}')" ''
expect 'JobThatLintsThenInstallsInOneStep_FailsTheLinterCheck because lint ran before its linters were there' "$(job_running '{"run": "tools/lint.sh\npython -m pip install -r tools/requirements-lint.txt"}')" release
expect 'JobThatRunsTheLintPartWithoutTheLinters_FailsTheLinterCheck because the lint part runs the same lint' "$(job_running '{"run": "tools/test.sh tools lint"}')" release
installing_with() {
  expect "JobThatInstallsWith${1}_PassesTheLinterCheck because pip takes a requirements file in this form" "$(job_running "{\"run\": \"python -m pip install $2\"}, {\"run\": \"tools/lint.sh\"}")" ''
}
installing_with TheShortOption '-r tools/requirements-lint.txt'
installing_with TheShortOptionJoinedToTheFile '-rtools/requirements-lint.txt'
installing_with TheLongOption '--requirement tools/requirements-lint.txt'
installing_with TheLongOptionAndAnEqualsSign '--requirement=tools/requirements-lint.txt'
expect 'JobThatInstallsThenLintsAfterASemicolon_PassesTheLinterCheck because a semicolon ends the install command' "$(job_running '{"run": "python -m pip install -r tools/requirements-lint.txt; tools/lint.sh"}')" ''
expect 'JobThatInstallsThenLintsAfterAnAndOperator_PassesTheLinterCheck because the lint runs only after the install' "$(job_running '{"run": "python -m pip install -r tools/requirements-lint.txt && tools/test.sh lint"}')" ''
expect 'JobThatLintsThenInstallsAfterASemicolon_FailsTheLinterCheck because lint ran before its linters were there' "$(job_running '{"run": "tools/lint.sh; python -m pip install -r tools/requirements-lint.txt"}')" release
expect 'JobWithACommentAboveItsInstall_PassesTheLinterCheck because a comment ends at its line' "$(job_running '{"run": "# Install the linters\npython -m pip install -r tools/requirements-lint.txt"}, {"run": "tools/lint.sh"}')" ''
expect 'JobWithACommentAfterItsInstall_PassesTheLinterCheck because a comment ends at its line' "$(job_running '{"run": "python -m pip install -r tools/requirements-lint.txt # the pinned linters\ntools/lint.sh"}')" ''
expect 'JobWithACommentAboveALintWithNoInstall_FailsTheLinterCheck because a comment hides no command below it' "$(job_running '{"run": "# lint this job\ntools/lint.sh"}')" release
expect 'JobWithAHashInsideAWordBeforeALint_FailsTheLinterCheck because only a hash that starts a word starts a comment' "$(job_running '{"run": "[ $# -eq 0 ] && tools/lint.sh"}')" release
expect 'JobWhoseInstallIsOnlyInAComment_FailsTheLinterCheck because a comment installs nothing' "$(job_running '{"run": "# python -m pip install -r tools/requirements-lint.txt\ntools/lint.sh"}')" release
expect 'JobThatLintsByAPathFromTheFolder_FailsTheLinterCheck because ./tools/lint.sh is the same script' "$(job_running '{"run": "./tools/lint.sh"}')" release
expect 'JobThatInstallsByAPathFromTheFolder_PassesTheLinterCheck because ./tools/requirements-lint.txt is the same file' "$(job_running '{"run": "python -m pip install -r ./tools/requirements-lint.txt\nsh ./tools/lint.sh"}')" ''
expect 'JobThatLintsInsideAnIfWithNoInstall_FailsTheLinterCheck because a keyword before the script hides no lint' "$(job_running '{"run": "if true; then tools/lint.sh; fi"}')" release
expect 'JobThatOnlyPrintsTheNameOfTheLintScriptInASentence_PassesTheLinterCheck because a quoted sentence runs nothing' "$(job_running '{"run": "echo \"run tools/lint.sh later\""}')" ''
