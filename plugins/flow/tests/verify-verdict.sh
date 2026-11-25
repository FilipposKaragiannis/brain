#!/bin/sh
# verify-verdict.sh: every report verify writes names the full head commit and opens with its
# verdict line, on a pass, a fail, a run stopped at verify.limit, a run killed or ended by TERM and
# a run whose report could not be built; and a report with nothing unchecked still has its Not
# checked list, which says none. On the local adapter in throwaway repos.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
# shellcheck disable=SC2034,SC2154 # the fixtures this sources set and read these names, and check reads them inside its quoted conditions
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
# The sandbox removes the folder on exit, which lets every held gate and stand-in run go.
. "$here/_verify_fixture.sh"

full_head() { git -C "$worktree" rev-parse HEAD; }
report_head() { json_value head < "$reports/verify.json"; }
report_first_line() { head -n 1 "$reports/verify.md"; }
# not_checked_body: the first line under verify.md's `## Not checked` heading that is not blank.
not_checked_body() { awk 'found && NF { print; exit } /^## Not checked$/ { found = 1 }' "$reports/verify.md"; }
# check_report_carries_the_full_commit <scenario> <status>: the JSON head and the Markdown verdict
# line of the item's report, each against the worktree's full head commit.
check_report_carries_the_full_commit() {
  check_report_carries_the_full_commit_status="$2"
  check "${1}_JsonHeadIsTheFullCommit: a reviewer must match the report to one exact commit, never a short sha that can collide" \
    '[ "$(report_head)" = "$(full_head)" ]'
  check "${1}_MarkdownOpensWithTheVerdictAtTheFullCommit: the first line says pass or fail and the commit it holds for" \
    '[ "$(report_first_line)" = "Verdict: $check_report_carries_the_full_commit_status at $(full_head)" ]'
}
# end_the_held_run <signal>: starts the item's run, waits for its gate, sends the signal to the
# run's process group and waits for --wait to report the run's end.
end_the_held_run() {
  verify --start >/dev/null 2>&1
  until_true 20 "[ -s $work/$(basename "$root").count ]"
  end_the_held_run_pid="$(run_pid)"
  kill "-$1" -- "-$end_the_held_run_pid" 2>/dev/null || kill "-$1" "$end_the_held_run_pid"
  until_true 20 "! process_running $end_the_held_run_pid"
  wait_until_ended
}

echo "a plain run that passes"
new_item passing "  ok: 'true'"
verify >/dev/null 2>&1
check_report_carries_the_full_commit PassingRun pass
check "PassingRunWithNothingUnchecked_MarkdownNotCheckedSaysNone: the list is always there, so its absence never reads as all checked" \
  '[ "$(not_checked_body | tr "[:upper:]" "[:lower:]" | tr -d ".")" = none ]'
check "PassingRunWithNothingUnchecked_JsonNotCheckedIsAnEmptyList: a reader finds the field on every report, empty when nothing was left out" \
  '[ "$(json_value not_checked < "$reports/verify.json")" = "[]" ]'

echo "a plain run whose gate fails"
new_item failing "  broken: 'false'"
verify >/dev/null 2>&1
check_report_carries_the_full_commit FailingRun fail

echo "a run stopped at verify.limit"
limit_seconds=5
limit_yaml="verify:
  limit: ${limit_seconds}s
"
new_item limited "  slow: 'sh -c \"while [ -d $work ]; do sleep 1; done\"'"
limit_yaml=""
verify --start >/dev/null 2>&1
wait_until_ended
check_report_carries_the_full_commit RunPastTheLimit fail

for ending in KILL TERM; do
  echo "a run ended by $ending"
  new_item "ended-by-$ending" "$(held_gate "ended-by-$ending")"
  end_the_held_run "$ending"
  check_report_carries_the_full_commit "RunEndedBy$ending" fail
  check "RunEndedBy${ending}WithNothingUnchecked_MarkdownNotCheckedSaysNone: the minimal fail report keeps the list too" \
    '[ "$(not_checked_body | tr "[:upper:]" "[:lower:]" | tr -d ".")" = none ]'
done

echo "a run whose report cannot be built"
new_item unbuildable "  ok: 'true'"
mkdir -p "$work/broken-builder"
printf '#!/bin/sh\ncase "$*" in *_verify_report.py*) echo "report builder broke" >&2; exit 1 ;; esac\nexec %s "$@"\n' \
  "$(command -v python3)" > "$work/broken-builder/python3"
chmod +x "$work/broken-builder/python3"
(PATH="$work/broken-builder:$PATH"; export PATH; verify >/dev/null 2>&1)
check_report_carries_the_full_commit UnbuildableReport fail

if [ "$fails" -eq 0 ]; then echo "verify-verdict: ok"; else echo "verify-verdict: $fails failed"; exit 1; fi
