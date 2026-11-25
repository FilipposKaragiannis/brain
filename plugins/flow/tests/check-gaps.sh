#!/bin/sh
# shellcheck disable=SC2034,SC2154 # _base_fixture.sh sets plugin, work, local_adapter, root and fails; the checks' conditions read the names set here
# check-gaps.sh: a scheduled check that cannot run, in a throwaway repo with a bare origin and the
# local adapter. init --check names each malformed jobs.checks entry, jobs.checks set as a value,
# a jobs.schedule.check-<name> key and a base no check can check out as a gap at its line in the
# config; jobs.sh run refuses a check with no command, run and install refuse one whose base is
# no valid branch name, and bare install refuses a jobs.schedule.check-<name> key; a config whose
# checks can all run is no gap.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

# The exit code jobs.sh gives a name or a setting it refuses.
refused_exit=2
jobs_script="$plugin/scripts/jobs.sh"
init_script="$plugin/skills/init/scripts/init.sh"

new_repo check-gaps
flow_home_folder="$(cd "$root" && pwd -P)/app/.flow"
# The wrapper run needs, so the entry or the base is all it can refuse.
mkdir -p .flow/jobs && printf '#!/bin/sh\nexec "%s" "$@"\n' "$plugin/jobs/check.sh" > .flow/jobs/check.sh && chmod +x .flow/jobs/check.sh
# config_line <key>: the line of the config that sets the key, the first one when two share it.
config_line() { grep -n "^ *$1:" "$flow_home_folder/config.yaml" | head -1 | cut -d: -f1; }
# init_gaps <file>: init --check on the config now in place, its output in the file.
init_gaps() { "$init_script" --check > "$1" 2>&1; }
# gap_named <output> <entry> <key>: true when init named the entry as a gap at the key's line.
gap_named() {
  entry_line="$(config_line "$3")"
  [ -n "$entry_line" ] && grep -qF "init: gap: .flow/config.yaml:$entry_line: $2: " "$1"
}
# good_config <base>: prints a config whose one check can run, on the base.
good_config() {
  cat <<YAML
adapters:
  default: local
base: $1
pool:
  - ../wt-1
jobs:
  checks:
    smoke:
      command: true
      schedule: daily 02:00
YAML
}

echo "check gaps: init names a malformed check"
cat > "$flow_home_folder/config.yaml" <<YAML
adapters:
  default: local
base: main
pool:
  - ../wt-1
jobs:
  schedule:
    health: every 15m
    check-x: daily 02:00
  checks:
    dashed-name:
      command: true
      schedule: daily 02:00
    Upper:
      command: true
      schedule: daily 02:00
    nocommand:
      schedule: daily 02:00
    noschedule:
      command: true
    nightly:
      command: true
      schedule: nightly
    withargs:
      command: true
      schedule: daily 02:00 --workers 2
    listed:
      command: [ -f README.md ]
      schedule: daily 02:00
    scalar: true
YAML
init_gaps "$work/init-malformed.out"
check "CheckNameWithADash_IsAnInitGapAtItsLine: init names the entry and its line" \
  'gap_named "$work/init-malformed.out" jobs.checks.dashed-name dashed-name'
check "CheckNameWithAnUppercaseLetter_IsAnInitGapAtItsLine: init names the entry and its line" \
  'gap_named "$work/init-malformed.out" jobs.checks.Upper Upper'
check "CheckWithNoCommand_IsAnInitGapAtItsLine: init names the entry and its line" \
  'gap_named "$work/init-malformed.out" jobs.checks.nocommand nocommand'
check "CheckWithNoSchedule_IsAnInitGapAtItsLine: init names the entry and its line" \
  'gap_named "$work/init-malformed.out" jobs.checks.noschedule noschedule'
check "CheckWithAnUnreadableSchedule_IsAnInitGapAtItsLine: nightly is no schedule, so init names the entry and its line" \
  'gap_named "$work/init-malformed.out" jobs.checks.nightly nightly'
check "CheckWithScheduleArgs_IsAnInitGapAtItsLine: a check's schedule is the timing alone, so init names the entry and its line" \
  'gap_named "$work/init-malformed.out" jobs.checks.withargs withargs'
check "CheckCommandStartingWithABracket_IsAnInitGapAtItsLine: the config reads it as a list, so init names the entry and its line" \
  'gap_named "$work/init-malformed.out" jobs.checks.listed listed'
check "CheckSetAsAValue_IsAnInitGapAtItsLine: an entry holds a command and a schedule, so init names a scalar one and its line" \
  'gap_named "$work/init-malformed.out" jobs.checks.scalar scalar'
check "CheckUnderJobsSchedule_IsAnInitGapAtItsLine: a check is set under jobs.checks, so init names the jobs.schedule key and its line" \
  'gap_named "$work/init-malformed.out" jobs.schedule.check-x check-x'
printf 'base: main\njobs:\n  checks: smoke\n' > "$flow_home_folder/config.yaml"
init_gaps "$work/init-scalar-checks.out"
check "ChecksSetAsAValue_IsAnInitGapAtItsLine: jobs.checks holds the checks by name, so init names a value there and its line" \
  'gap_named "$work/init-scalar-checks.out" jobs.checks checks'

echo "check gaps: a base no check can check out"
good_config "--upload-pack=true" > "$flow_home_folder/config.yaml"
init_gaps "$work/init-option-base.out"
check "BaseGitReadsAsAnOptionBesideACheck_IsAnInitGapAtItsLine: git would take the base for an option, so init names it and its line" \
  'gap_named "$work/init-option-base.out" base base'
"$jobs_script" run check-smoke > "$work/run-option-base.out" 2>&1; run_option_base_exit=$?
check "BaseGitReadsAsAnOption_IsRefusedByRun: no check can check that base out, so run refuses it" \
  '[ "$run_option_base_exit" -eq "$refused_exit" ]'
FLOW_SCHEDULER=launchd FLOW_LAUNCH_AGENTS="$work/agents" "$jobs_script" install check-smoke > "$work/install-option-base.out" 2>&1; install_option_base_exit=$?
check "BaseGitReadsAsAnOption_IsRefusedByInstall: no check can check that base out, so install refuses it" \
  '[ "$install_option_base_exit" -eq "$refused_exit" ]'

echo "check gaps: run refuses a malformed check"
{ good_config main; printf '    nocommand:\n      schedule: daily 02:00\n'; } > "$flow_home_folder/config.yaml"
"$jobs_script" run check-nocommand > "$work/run-malformed.out" 2>&1; run_malformed_exit=$?
check "CheckWithNoCommand_IsRefusedByRun: a check with no command cannot run, so run refuses it" \
  '[ "$run_malformed_exit" -eq "$refused_exit" ]'

echo "check gaps: bare install refuses a check under jobs.schedule"
printf 'base: main\njobs:\n  schedule:\n    health: every 15m\n    check-smoke: daily 02:00\n' > "$flow_home_folder/config.yaml"
misplaced_line="$(config_line check-smoke)"
FLOW_SCHEDULER=cron "$jobs_script" install > "$work/install-misplaced.out" 2>&1; install_misplaced_exit=$?
check "CheckUnderJobsScheduleBesideAJob_IsRefusedByBareInstall: install with no name refuses the key rather than install the job alone" \
  '[ "$install_misplaced_exit" -eq "$refused_exit" ]'
check "CheckUnderJobsScheduleBesideAJob_BareInstallNamesItsLine: the refusal names the jobs.schedule key and its config line" \
  'grep -q "config.yaml:$misplaced_line: jobs.schedule.check-smoke: " "$work/install-misplaced.out"'

echo "check gaps: good checks are none"
good_config main > "$flow_home_folder/config.yaml"
init_gaps "$work/init-good.out"
check "OnlyGoodChecks_InitCheckReports: init --check prints its report, so a missing gap line is a real absence" \
  '[ -s "$work/init-good.out" ]'
check "OnlyGoodChecks_AreNoInitGap: init names no jobs.checks entry when every check can run" \
  '! grep -q "^init: gap: [^ ]*: \(base\|jobs\.\(checks\|schedule\.check-\)\)" "$work/init-good.out"'

[ "$fails" -eq 0 ] && { echo "check gaps: ok"; exit 0; }
echo "check gaps: $fails failed"; exit 1
