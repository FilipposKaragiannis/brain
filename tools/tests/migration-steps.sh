#!/bin/sh
# migration-steps.sh: tools/lib/migration_steps.py, the lint check of the config migration steps,
# on fixture trees: the base tree under fixtures/migration-steps/base with one case's files laid
# over it, then on this repository. Takes no argument. Exit 0 when every check passes, 1 on any
# failure. tools/test.sh runs it with the tools part.
set -u
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
. "$root/tools/lib/sandbox.sh"; sandbox_enter "$work" "$root/tools"
trap 'sandbox_close $?' EXIT
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { check_name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$check_name"; else fail "$check_name"; fi; }

fixtures="$here/fixtures/migration-steps"
lint_check="$root/tools/lib/migration_steps.py"
passes_exit=0
finding_exit=1
output="$work/output"

lint_case() {
  lint_case_tree="$work/tree-$1"
  rm -rf "$lint_case_tree"; cp -R "$fixtures/base" "$lint_case_tree"
  [ "$1" = base ] || cp -R "$fixtures/$1/." "$lint_case_tree"
  python3 -I -B "$lint_check" "$lint_case_tree" > "$output" 2>&1; lint_case_exit=$?
}
exited() { [ "$lint_case_exit" -eq "$1" ]; }
printed() { grep -q -e "$1" "$output"; }
printed_finding() { grep -v '^lint: note:' "$output" | grep -q -e "$1"; }

echo "the base tree"
lint_case base
check "MigrationSteps_BaseTree_Passes" exited "$passes_exit"

echo "schema keys against the steps"
lint_case added-key
check "MigrationSteps_SchemaKeyAddedWithoutStep_ExitsWithAFinding" exited "$finding_exit"
check "MigrationSteps_SchemaKeyAddedWithoutStep_FailsNamingTheKey" printed_finding 'gamma'
lint_case removed-key
check "MigrationSteps_SchemaKeyRemovedWithoutStep_ExitsWithAFinding" exited "$finding_exit"
check "MigrationSteps_SchemaKeyRemovedWithoutStep_FailsNamingTheKey" printed_finding 'beta\.two'
lint_case known-step
check "MigrationSteps_KnownStep_LetsAnAddedKeyPass" exited "$passes_exit"
lint_case reintroduced-key
check "MigrationSteps_StepReintroducesARetiredKey_Fails" exited "$finding_exit"
check "MigrationSteps_StepReintroducesARetiredKey_NamesTheKey" printed_finding 'old\.mode'

echo "fallbacks"
lint_case retired-without-fallback
check "MigrationSteps_RetiredKeyInMirrorWithoutFallback_Fails" exited "$finding_exit"
lint_case fallback-file-stale
check "MigrationSteps_FallbackFileNoLongerReadsTheKey_Fails" exited "$finding_exit"
check "MigrationSteps_FallbackFileNoLongerReadsTheKey_NamesTheFile" printed_finding 'lib/reader\.txt'
lint_case fallback-file-missing
check "MigrationSteps_FallbackFileMissing_Fails" exited "$finding_exit"
check "MigrationSteps_FallbackFileMissing_NamesTheFile" printed_finding 'lib/gone\.txt'
lint_case version-past-after
check "MigrationSteps_VersionPastAfter_Passes" exited "$passes_exit"
check "MigrationSteps_VersionPastAfter_NotesTheStep" printed '^lint: note: .*mode-moves'

echo "step list shape"
lint_case duplicate-name
check "MigrationSteps_DuplicateStepName_Fails" exited "$finding_exit"
check "MigrationSteps_DuplicateStepName_NamesTheStep" printed_finding 'mode-moves'
lint_case unknown-op
check "MigrationSteps_UnknownOp_Fails" exited "$finding_exit"
check "MigrationSteps_UnknownOp_NamesTheOp" printed_finding 'rename'

echo "this repository"
python3 -I -B "$lint_check" "$root" > "$output" 2>&1; lint_case_exit=$?
check "MigrationSteps_ThisRepository_Passes" exited "$passes_exit"

[ "$fails" -eq 0 ] && echo "migration-steps: ok"
[ "$fails" -eq 0 ]
