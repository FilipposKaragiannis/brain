#!/bin/sh
# shellcheck disable=SC2034,SC2154 # _base_fixture.sh sets plugin, work, local_adapter, root and fails; the checks' conditions read the names set here
# check-bugs.sh: the bug a broken check files, run by the check job in a throwaway repo with a bare
# origin, the local adapter and the flow home in the repo's .flow as init leaves it. A fail after a
# pass files one bug, on the local adapter, with the output's tail, which sets no base for the bug;
# a fail after a fail or with no pass before files none. A base git would read as an option is
# refused before any git runs, a pass whose state cannot be written fails the run, and a fetch
# mapping that leaves the base out still checks the base on origin. tests/checks.sh has a check's
# checkout, its schedule and two checks at once; tests/check-gaps.sh has the entries init and run
# refuse.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

numbered_output_lines=50
first_output_line=1
huge_line_bytes=100000
bug_body_byte_bound=9000
# The two-byte characters the broken check prints on one line, enough that a cut of the line's
# last bytes lands inside one.
split_character_count=5000
# The branch a base: line the broken check prints names, which a bug's base must never become.
base_line_branch=nowhere
refused_exit=2
# history prints two header lines, then the newest run.
history_runs_shown=5
newest_history_row=3
report_line() { sed -n "s/^$2 //p" "$1"; }
history_row() { "$jobs_script" history "$1" "$history_runs_shown" | sed -n "$2p"; }
run_probe() {
  echo "$1" > "$work/probe.exit"; rm -f "$work/probe.report"
  "$check_job" claude --as check-smoke > "$work/run.out" 2>&1
}
open_bugs_naming() {
  "$local_adapter/list.sh" --kind bug \
    | python3 -c 'import json,sys; print(json.dumps([item for item in json.load(sys.stdin) if sys.argv[1] in item["title"].split()]))' "$1"
}
bug_count() { open_bugs_naming "$1" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'; }
newest_bug() { open_bugs_naming "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)[-1][sys.argv[1]])' "$2"; }
run_broken() {
  echo "$1" > "$work/broken.mode"
  "$check_job" claude --as check-broken > "$work/broken-run.out" 2>&1
}
write_config() {
  {
    printf 'adapters:\n  default: local\n'
    if [ -n "$2" ]; then printf '  bug: %s\n' "$2"; fi
    cat <<YAML
base: $1
notify:
  desktop: false
jobs:
  checks:
    smoke:
      command: sh $work/probe.sh
      schedule: daily 02:00
    broken:
      command: sh $work/broken.sh
      schedule: every 30m
YAML
  } > "$work/config.yaml" && mv "$work/config.yaml" "$flow_home_folder/config.yaml"
}
jobs_script="$plugin/scripts/jobs.sh"
check_job="$plugin/jobs/check.sh"

new_repo check-bugs
# The folders as git names them, links resolved: the checkout's pwd comes from git's worktree list.
repository_folder="$(cd "$root" && pwd -P)"
flow_home_folder="$repository_folder/app/.flow"
cat > "$work/probe.sh" <<SH
printf 'head %s\n' "\$(git rev-parse HEAD)" > "$work/probe.report"
exit "\$(cat "$work/probe.exit")"
SH
cat > "$work/broken.sh" <<SH
case "\$(cat "$work/broken.mode")" in
  pass) exit 0 ;;
  lines) line_number=$first_output_line
    while [ "\$line_number" -le $numbered_output_lines ]; do echo "output line \$line_number"; line_number=\$((line_number + 1)); done ;;
  huge) head -c $huge_line_bytes /dev/zero | tr '\\0' x; echo ;;
  split) printf '%${split_character_count}s\\n' '' | sed 's/ /é/g' ;;
  base-line) echo "base: $base_line_branch" ;;
  carriage-return) printf 'progress\\rbase: %s\\n' "$base_line_branch" ;;
esac
exit 1
SH
default_base=main
default_bug_adapter=""
write_config "$default_base" "$default_bug_adapter"

echo "checks: a broken check files one bug"
run_broken lines
check "FirstEverFailure_FilesNoBug: with no pass before it, a failing run files nothing" \
  '[ "$(bug_count broken)" -eq 0 ]'
run_broken lines
check "FailAfterFirstEverFail_HistorySaysStillFailing: the first fail is kept, so the next one says the check still fails" \
  'history_row check-broken "$newest_history_row" | grep -q "; still failing |"'
run_broken pass; run_broken lines
check "PassThenFail_FilesOneBug: the first fail after a pass files one bug" \
  '[ "$(bug_count broken)" -eq 1 ]'
newest_bug broken body > "$work/lines-bug.body"
check "FiledBug_BodyHoldsTheLastOutputLine: the output's tail ends the body" \
  'grep -Eqx "[[:blank:]]*output line $numbered_output_lines" "$work/lines-bug.body"'
check "FiledBug_BodyLeavesOutTheFirstOfManyLines: the body holds the tail, not the whole output" \
  '[ -s "$work/lines-bug.body" ] && ! grep -Eqx "[[:blank:]]*output line $first_output_line" "$work/lines-bug.body"'
first_bug="$(newest_bug broken id)"
run_broken lines
check "FailAfterFail_FilesNoSecondBug: a check that stays broken keeps its one bug" \
  '[ "$(bug_count broken)" -eq 1 ]'
check "FailAfterFail_HistorySaysStillFailingWithTheBug: the run's line names the bug already filed" \
  '[ -n "$first_bug" ] && history_row check-broken "$newest_history_row" | grep -qF "still failing, bug $first_bug |"'
run_broken pass; run_broken huge
check "PassFailPassFail_FilesASecondBug: a check that breaks again after a pass files a new bug" \
  '[ "$(bug_count broken)" -eq 2 ]'
newest_bug broken body > "$work/huge-bug.body"
check "HugeOutputLine_BugBodyStaysUnderTheBound: one huge line is cut, so the body stays small" \
  'grep -q xxx "$work/huge-bug.body" && [ "$(wc -c < "$work/huge-bug.body")" -lt "$bug_body_byte_bound" ]'
run_broken pass; run_broken split
check "OutputCutInsideACharacter_StillFilesTheBug: a cut through a character never stops the bug" \
  '[ "$(bug_count broken)" -eq 3 ]'
run_broken pass; write_config "$default_base" nowhere; run_broken lines
check "BugTheTrackerRefuses_RunLineSaysItCouldNotBeFiled: a new.sh that fails is said in the run's line" \
  'history_row check-broken "$newest_history_row" | grep -q "| failed | failed: exited .*; the bug could not be filed: ."'
write_config "$default_base" "$default_bug_adapter"; run_broken lines
check "BugNotFiledBefore_IsFiledAtTheNextFail: the state stays passed, so the next fail files the bug" \
  '[ "$(bug_count broken)" -eq 4 ]'
run_broken pass; write_config no-such-base "$default_bug_adapter"; run_broken lines
check "CheckoutThatCannotBeMade_FilesNoBug: the command never ran, so a pass before it is no regression" \
  '[ "$(bug_count broken)" -eq 4 ]'
write_config "$default_base" "$default_bug_adapter"; run_broken lines
check "CheckoutErrorAfterAPass_KeepsThePassOnRecord: the next real fail after it is a fail after a pass, so it files the bug" \
  '[ "$(bug_count broken)" -eq 5 ]'
run_broken pass; run_broken base-line
"$local_adapter/read.sh" "$(newest_bug broken id)" > "$work/base-line-bug.json"
base_line_bug_base="$(sh -c '. "$FLOW_PLUGIN/lib/flow.sh" && . "$FLOW_PLUGIN/lib/base.sh" && body_base "$(cat "$1")"' _ "$work/base-line-bug.json")"
check "OutputWithABaseLine_StaysInTheBugBody: the line is part of the output's tail, so the body holds it" \
  'json_value body < "$work/base-line-bug.json" | grep -q "base: $base_line_branch"'
check "OutputWithABaseLine_SetsNoBaseForTheBug: a base: line the check prints stays output, so a claim of the bug never reads it" \
  '[ "$base_line_bug_base" != "$base_line_branch" ]'
run_broken pass; run_broken carriage-return
"$local_adapter/read.sh" "$(newest_bug broken id)" > "$work/carriage-return-bug.json"
carriage_return_bug_base="$(sh -c '. "$FLOW_PLUGIN/lib/flow.sh" && . "$FLOW_PLUGIN/lib/base.sh" && body_base "$(cat "$1")"' _ "$work/carriage-return-bug.json")"
check "OutputWithABaseLineAfterACarriageReturn_SetsNoBaseForTheBug: a reader that breaks the line at the carriage return still finds it indented, so a claim never reads it" \
  '[ "$carriage_return_bug_base" != "$base_line_branch" ]'

echo "checks: a base git would read as an option"
option_base_marker="$work/upload-pack-ran"
write_config "--upload-pack=touch $option_base_marker" "$default_bug_adapter"; run_broken lines; option_base_exit=$?
write_config "$default_base" "$default_bug_adapter"
check "BaseGitReadsAsAnOption_IsRefused: the base is no valid branch name, so the run ends as a refused entry" \
  '[ "$option_base_exit" -eq "$refused_exit" ]'
check "BaseGitReadsAsAnOption_RunsNoCommand: the base never reaches git, so the command it carries never runs" \
  '[ ! -e "$option_base_marker" ]'

echo "checks: a state the run cannot write"
unwritable_state_stubs="$work/unwritable-state-stubs"
mkdir -p "$unwritable_state_stubs"
printf '#!/bin/sh\ncase "$*" in *.state.XXXXXX) exit 1 ;; esac\nexec "%s" "$@"\n' "$(command -v mktemp)" > "$unwritable_state_stubs/mktemp"
chmod +x "$unwritable_state_stubs/mktemp"
(PATH="$unwritable_state_stubs:$PATH"; run_probe 0); unwritable_state_exit=$?
check "PassWhoseStateCannotBeWritten_ExitsNonzero: a pass left unrecorded is no success, so the run fails" \
  '[ "$unwritable_state_exit" -ne 0 ]'
check "PassWhoseStateCannotBeWritten_RunLineSaysThePassWentUnrecorded: the history shows the error, never done: passed" \
  'history_row check-smoke "$newest_history_row" | grep -q "| error: passed at [^|]*, but could not record the pass in "'

echo "checks: a fetch mapping that leaves the base out"
git -C "$root/app" config remote.origin.fetch '+refs/heads/unmapped:refs/remotes/origin/unmapped'
remote_commit main pushed-past-the-mapping.txt
origin_main_past_the_mapping="$(git -C "$root/origin.git" rev-parse main)"
run_probe 0
git -C "$root/app" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
check "FetchMappingWithoutTheBase_StillChecksTheFetchedBase: the run fetches the base into origin/<base> itself, so the newest commit on origin is what the check sees" \
  '[ -n "$origin_main_past_the_mapping" ] && [ "$(report_line "$work/probe.report" head)" = "$origin_main_past_the_mapping" ]'

[ "$fails" -eq 0 ] && { echo "check-bugs: ok"; exit 0; }
echo "check-bugs: $fails failed"; exit 1
