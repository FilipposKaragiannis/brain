#!/bin/sh
# main-worktree-once.sh: lib/flow.sh finds the main worktree once per working folder and probes
# git once per invocation tree, and hands both to child scripts through the environment. An
# explicit FLOW_HOME, a linked worktree, a cd to another repository, a nested repository and a
# folder outside any repository still resolve as before, and a git first on PATH that lists the
# worktrees only so often shows one flow command still reads its config on that many listings.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

RATIONED_GIT_REAL="$(command -v git)"; RATIONED_GIT_LISTINGS="$work/listings-left"
export RATIONED_GIT_REAL RATIONED_GIT_LISTINGS
mkdir -p "$work/rationed" "$work/scripts"
cat > "$work/rationed/git" <<'SCRIPT'
#!/bin/sh
case "$*" in "worktree list --porcelain")
  left="$(cat "$RATIONED_GIT_LISTINGS")"
  [ "$left" -gt 0 ] || { echo "fatal: no worktree listing left" >&2; exit 128; }
  echo $((left - 1)) > "$RATIONED_GIT_LISTINGS" ;;
esac
exec "$RATIONED_GIT_REAL" "$@"
SCRIPT
chmod +x "$work/rationed/git"
cat > "$work/scripts/flow-home.sh" <<'SCRIPT'
# flow-home.sh [folder]: the flow home, read after a cd to the folder when one is given.
. "$FLOW_PLUGIN/lib/flow.sh"
[ $# -eq 0 ] || cd "$1" || exit 1
flow_home
SCRIPT
cat > "$work/scripts/child-flow-home.sh" <<'SCRIPT'
# child-flow-home.sh <folder>: the flow home a child script started in the folder reads.
. "$FLOW_PLUGIN/lib/flow.sh"
cd "$1" || exit 1
sh "$(dirname "$0")/flow-home.sh"
SCRIPT
cat > "$work/scripts/three-keys.sh" <<'SCRIPT'
# three-keys.sh: three config reads in one script.
. "$FLOW_PLUGIN/lib/flow.sh"
cfg base; cfg pool; cfg adapters.default
SCRIPT
cat > "$work/scripts/resolve-after-cd.sh" <<'SCRIPT'
# resolve-after-cd.sh <folder>: three config reads after a cd to the folder and a new resolve.
. "$FLOW_PLUGIN/lib/flow.sh"
cd "$1" || exit 1
main_worktree_resolve
cfg base; cfg pool; cfg adapters.default
SCRIPT
cat > "$work/scripts/child-with-own-git.sh" <<'SCRIPT'
# child-with-own-git.sh <folder of a git>: the flow home a child reads with that git first on PATH.
. "$FLOW_PLUGIN/lib/flow.sh"
PATH="$1:$PATH" sh "$(dirname "$0")/flow-home.sh"
SCRIPT
mkdir -p "$work/broken-git" "$work/stub-git"
printf '#!/bin/sh\necho "xcrun: error: Failed to locate '\''git'\''" >&2\nexit 1\n' > "$work/broken-git/git"
cat > "$work/stub-git/git" <<SCRIPT
#!/bin/sh
case "\$*" in "worktree list --porcelain") printf 'worktree %s\n' "$work/stub-main" ;; *) exec "$RATIONED_GIT_REAL" "\$@" ;; esac
SCRIPT
chmod +x "$work/broken-git/git" "$work/stub-git/git"
xcode_git=/Applications/Xcode.app/Contents/Developer/usr/bin/git
git_behind_a_broken_shim=git; [ ! -x "$xcode_git" ] || git_behind_a_broken_shim="$xcode_git"
cat > "$work/scripts/git-program.sh" <<'SCRIPT'
# git-program.sh: the git lib/flow.sh settled on.
. "$FLOW_PLUGIN/lib/flow.sh"
printf '%s' "$FLOW_GIT_PROGRAM"
SCRIPT
scripts="$work/scripts"

# rationed <listings> <command...>: what the command prints with a git first on PATH that lists
# the worktrees that many times and fails every listing after.
rationed() {
  printf '%s\n' "$1" > "$RATIONED_GIT_LISTINGS"; shift
  (PATH="$work/rationed:$PATH"; export PATH; "$@") 2>/dev/null
}

new_repo resolving
app="$(pwd -P)"; other="$(cd "$root/other" && pwd -P)"; nested="$app/nested"
mkdir -p "$nested" "$work/no-repository" && git -C "$nested" init -q
three_keys_in_app="$(sh "$scripts/three-keys.sh")"
[ -n "$three_keys_in_app" ] || { echo "fixture: the main worktree's config reads nothing"; exit 1; }

echo "main worktree once: where the flow home is"
check "ExplicitFlowHome_WinsOverTheMainWorktree: a caller that names the home gets that home" \
  '[ "$(env FLOW_HOME="$work/elsewhere" sh "$scripts/flow-home.sh")" = "$work/elsewhere" ]'
check "LinkedWorktree_ResolvesToTheMainWorktreesFlowHome: every worktree of a clone shares one config" \
  '[ "$(cd "$root/wt-1" && sh "$scripts/flow-home.sh")" = "$app/.flow" ]'
check "ChildScriptStartedInALinkedWorktree_ResolvesToTheMainWorktreesFlowHome: the answer its parent found for another folder is not taken" \
  '[ "$(sh "$scripts/child-flow-home.sh" "$root/wt-1")" = "$app/.flow" ]'
check "CdToAnotherRepositoryInsideOneScript_ResolvesTheOtherRepository: a script that moves between clones reads the clone it is in" \
  '[ "$(sh "$scripts/flow-home.sh" "$root/other")" = "$other/.flow" ]'
check "NestedRepository_ResolvesTheInnerRepository: a repository inside another one has its own home" \
  '[ "$(sh "$scripts/child-flow-home.sh" "$nested")" = "$nested/.flow" ]'
check "FolderThatIsNoRepository_UsesTheFolderItself: outside git the flow home is the working folder's" \
  '[ "$(sh "$scripts/child-flow-home.sh" "$work/no-repository")" = "$work/no-repository/.flow" ]'
check "AnswerHandedDownForAnotherFolder_IsIgnored: a value is trusted only in the folder it was found for" \
  '[ "$(env FLOW_MAIN_WORKTREE="$work/no-repository" FLOW_MAIN_WORKTREE_FOLDER="$work/no-repository" sh "$scripts/flow-home.sh")" = "$app/.flow" ]'
check "GitDirNamingAnotherRepository_IgnoresTheHandedDownAnswer: a repository the caller names wins over the answer found for the folder" \
  '[ "$(env GIT_DIR="$root/other/.git" FLOW_MAIN_WORKTREE="$work/no-repository" FLOW_MAIN_WORKTREE_FOLDER="$PWD" FLOW_MAIN_WORKTREE_SEARCH_PATH="$PATH" sh "$scripts/flow-home.sh")" != "$work/no-repository/.flow" ]'
check "StubGitPutOnPathForAChild_AnswersForTheChild: a stub the caller puts first on PATH is asked though the parent handed down an answer for the same folder" \
  '[ "$(sh "$scripts/child-with-own-git.sh" "$work/stub-git")" = "$work/stub-main/.flow" ]'
check "StubGitPutOnPathForAChildOfAParentOnXcodesGit_AnswersForTheChild: a git probe found for another PATH is not taken" \
  '[ "$(env FLOW_GIT_PROGRAM="$xcode_git" FLOW_GIT_SEARCH_PATH="$PATH" sh "$scripts/child-with-own-git.sh" "$work/stub-git")" = "$work/stub-main/.flow" ]'

echo "main worktree once: how often git is asked"
check "AnswerHandedDownForThisFolder_ReadsTheConfigOnNoListing: a child script in its parent's folder takes the parent's answer" \
  '[ "$(cd "$root/wt-1" && rationed 0 env FLOW_MAIN_WORKTREE="$app" FLOW_MAIN_WORKTREE_FOLDER="$PWD" FLOW_MAIN_WORKTREE_SEARCH_PATH="$work/rationed:$PATH" sh "$scripts/three-keys.sh")" = "$three_keys_in_app" ]'
check "ScriptReadingThreeKeys_ReadsThemOnOneListing: config reads take the answer found when lib/flow.sh was sourced" \
  '[ "$(cd "$root/wt-1" && rationed 1 sh "$scripts/three-keys.sh")" = "$three_keys_in_app" ]'
check "CdAndResolveInsideOneScript_ReadsThreeKeysOnTwoListings: a script that moves to another clone and resolves again lists once per folder" \
  '[ "$(cd "$other" && rationed 2 sh "$scripts/resolve-after-cd.sh" "$root/wt-1")" = "$three_keys_in_app" ]'
check "NewTaskWithItsAdapterChildScripts_FilesTheTaskOnTwoListings: a flow command and the scripts it starts in its folder share one answer, where each config read once listed them" \
  'id="$(cd "$root/wt-1" && rationed 2 "$plugin/scripts/new.sh" task "Rationed task" --size S --body "$body")" && "$local_adapter/read.sh" "$id" >/dev/null'
check "GitProgramHandedDownForThisPath_IsTakenWithoutAProbe: a child script takes its parent's git where a probe would settle on another" \
  '[ "$(env FLOW_GIT_PROGRAM="$xcode_git" FLOW_GIT_SEARCH_PATH="$PATH" sh "$scripts/git-program.sh")" = "$xcode_git" ]'
check "GitProgramHandedDownThatIsNoKnownGit_IsProbedAgain: only git on PATH or Xcode's git is taken from the environment" \
  '[ "$(env FLOW_GIT_PROGRAM="$work/rationed/git" FLOW_GIT_SEARCH_PATH="$PATH" sh "$scripts/git-program.sh")" != "$work/rationed/git" ]'
check "BrokenGitShimFirstOnPath_SettlesOnXcodesGit: when the git on PATH cannot run, flow takes Xcode's git where it is installed" \
  '[ "$(PATH="$work/broken-git:$PATH" sh "$scripts/git-program.sh")" = "$git_behind_a_broken_shim" ]'

echo "main worktree once: the sandbox"
check "SuiteStartedWithTheHandedDownValues_DoesNotSeeThem: no test inherits a main worktree or a git probe from its caller" \
  '[ -z "$(env FLOW_MAIN_WORKTREE=x FLOW_MAIN_WORKTREE_FOLDER=y FLOW_MAIN_WORKTREE_SEARCH_PATH=z FLOW_GIT_PROGRAM=git FLOW_GIT_SEARCH_PATH=w sh -c ". \"\$1\"; sandbox_enter \"\$2\" \"\$3\"; printf %s \"\${FLOW_MAIN_WORKTREE-}\${FLOW_MAIN_WORKTREE_FOLDER-}\${FLOW_MAIN_WORKTREE_SEARCH_PATH-}\${FLOW_GIT_PROGRAM-}\${FLOW_GIT_SEARCH_PATH-}\"" sandboxed "$plugin/../../tools/lib/sandbox.sh" "$work/inner" "$plugin")" ]'

echo "$fails failed"
[ "$fails" -eq 0 ]
