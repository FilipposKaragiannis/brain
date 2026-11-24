#!/bin/sh
# build-passed.sh: the build pass verify keeps and a push reads, on the local adapter in throwaway
# repos. scripts/build-passed.sh prints the run of a pass verify kept for the same build command and
# the files under its paths; a missing pass, a failed build, a changed command, a changed file under
# the paths and an uncommitted change there leave it silent. The standards pre-push hook, with the
# wrapper in the main worktree's flow home, skips the build it names and builds when there is none.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
. "$here/_verify_fixture.sh"

pre_push="$plugin/../standards/hooks/git/pre-push"
build_marker="$work/built"
# marking_build: a build command that leaves build_marker, and fails while fail-build exists.
marking_build() { printf 'touch %s; [ ! -f %s/fail-build ]' "$build_marker" "$work"; }
# commit_build_config <command>: commits .standards/config.json with the build at engine/** and no tests.
commit_build_config() {
  mkdir -p "$worktree/.standards"
  python3 -c 'import json,sys; json.dump({"version": "1", "build": {"command": sys.argv[2], "paths": ["engine/**"]}, "test": "", "mutation": "", "languages": []}, open(sys.argv[1], "w"))' \
    "$worktree/.standards/config.json" "$1"
  git -C "$worktree" add -A && git -C "$worktree" commit -qm "config"
}
# committed <path>: one more commit in the worktree that adds or changes the file.
committed() { mkdir -p "$(dirname "$worktree/$1")" && date +%s%N >> "$worktree/$1" && git -C "$worktree" add -A && git -C "$worktree" commit -qm "change $1"; }
# lookup_build_pass: runs scripts/build-passed.sh in the worktree and prints what it prints; its exit code is the function's.
lookup_build_pass() { (cd "$worktree" && "$plugin/scripts/build-passed.sh"); }
# install_lookup_wrapper: writes the build-passed.sh wrapper into the main worktree's flow home, as flow:init does.
install_lookup_wrapper() {
  printf '#!/bin/sh\nexec "%s/scripts/build-passed.sh" "$@"\n' "$plugin" > "$root/app/.flow/build-passed.sh"
  chmod +x "$root/app/.flow/build-passed.sh"
}
# push_after_clearing_the_marker: removes build_marker, then runs the pre-push hook in the worktree; its exit code is the function's.
push_after_clearing_the_marker() { rm -f "$build_marker"; (cd "$worktree" && "$pre_push" >/dev/null 2>&1); }
passing_gate="  ok: 'true'"

echo "build-passed: verify keeps the build it passed for a push"
new_item kept "$passing_gate"
commit_build_config "$(marking_build)"
committed engine/core.txt
verify >/dev/null 2>&1
kept_run="$(lookup_build_pass)"; kept_code=$?
check "BuildVerifyPassed_LookupExitsZero: a push may skip it, because verify built the same command on the same files" \
  '[ "$kept_code" -eq 0 ]'
check "BuildVerifyPassed_LookupNamesTheRunItCameFrom: the item whose verify passed it is printed, so the skip can be traced" \
  'printf "%s" "$kept_run" | grep -q -- "$item"'
committed notes/unrelated.txt
check "ChangeOutsideTheBuildPaths_LookupStillFindsThePass: nothing under engine/** changed, so the kept build still holds" \
  'lookup_build_pass >/dev/null'

echo "build-passed: the pre-push hook skips a build that passed"
install_lookup_wrapper
check "KeptPassBeforeThePush_IsFound: the push checks below need a kept pass" 'lookup_build_pass >/dev/null'
push_after_clearing_the_marker; skipped_push_code=$?
check "PushOfABuildVerifyPassed_ExitsZero: a build that passed is no reason to stop the push" '[ "$skipped_push_code" -eq 0 ]'
check "PushOfABuildVerifyPassed_DoesNotBuild: the build command never ran, because verify passed it on the same inputs" \
  '[ ! -e "$build_marker" ]'
skipped_push_said="$(rm -f "$build_marker"; cd "$worktree" && "$pre_push" 2>&1 >/dev/null)"
check "PushOfABuildVerifyPassed_SaysWhichRunPassedIt: the hook names the item, so the owner sees why no build ran" \
  'printf "%s" "$skipped_push_said" | grep -q -- "$item"'

echo "build-passed: a change under the build's paths builds again"
printf 'edited\n' >> "$worktree/engine/core.txt"
check "UncommittedChangeUnderTheBuildPaths_LookupFindsNothing: the files on disk are not the ones verify built" \
  '! lookup_build_pass >/dev/null'
push_after_clearing_the_marker
check "PushWithAnUncommittedChangeUnderTheBuildPaths_Builds: the build ran, because its inputs differ from the kept pass" \
  '[ -e "$build_marker" ]'
git -C "$worktree" checkout -q -- engine/core.txt
committed engine/core.txt
check "CommittedChangeUnderTheBuildPaths_LookupFindsNothing: a file the build reads changed since verify passed it" \
  '! lookup_build_pass >/dev/null'
push_after_clearing_the_marker
check "PushAfterAChangeUnderTheBuildPaths_Builds: the build ran, because no pass is kept for the new files" \
  '[ -e "$build_marker" ]'

echo "build-passed: a changed build command builds again"
new_item command "$passing_gate"
commit_build_config "$(marking_build)"
committed engine/core.txt
verify >/dev/null 2>&1
check "KeptPassBeforeTheCommandChanges_IsFound: the check below needs a kept pass to lose" 'lookup_build_pass >/dev/null'
commit_build_config "$(marking_build); true"
check "BuildCommandChanged_LookupFindsNothing: a pass is kept for one command text, so another command has none" \
  '! lookup_build_pass >/dev/null'

echo "build-passed: no pass, or a failed build, builds as today"
new_item unverified "$passing_gate"
commit_build_config "$(marking_build)"
committed engine/core.txt
check "BuildVerifyNeverRan_LookupFindsNothing: no run passed it, so there is nothing to name" '! lookup_build_pass >/dev/null'
install_lookup_wrapper
push_after_clearing_the_marker; unverified_push_code=$?
check "PushWithNoKeptPass_Builds: the build ran as it does today, because no run passed it" '[ -e "$build_marker" ]'
check "PushWithNoKeptPassAndAPassingBuild_ExitsZero: the build passed, so the push goes on" '[ "$unverified_push_code" -eq 0 ]'
: > "$work/fail-build"
push_after_clearing_the_marker; failing_push_code=$?
rm -f "$work/fail-build"
check "PushWithNoKeptPassAndAFailingBuild_ExitsOne: a broken build still stops the push" '[ "$failing_push_code" -eq 1 ]'

new_item dropped "$passing_gate"
commit_build_config "$(marking_build)"
committed engine/core.txt
verify >/dev/null 2>&1
check "KeptPassBeforeTheFailedBuild_IsFound: the check below needs a kept pass to drop" 'lookup_build_pass >/dev/null'
: > "$work/fail-build"
verify >/dev/null 2>&1
rm -f "$work/fail-build"
check "BuildThatFailsInALaterVerify_LookupFindsNothing: a known failure outranks the older pass on the same files" \
  '! lookup_build_pass >/dev/null'

if [ "$fails" -eq 0 ]; then echo "build-passed: ok"; else echo "build-passed: $fails failed"; exit 1; fi
