#!/bin/sh
# main-worktree-once.sh: lib/flow.sh finds the main worktree once per working folder and probes
# git once per invocation tree, and hands both to child scripts through the environment. An
# explicit FLOW_HOME, a linked worktree, a cd to another repository, a nested repository and a
# folder outside any repository still resolve as before, and a counting git first on PATH shows
# how often one flow command lists the worktrees.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

COUNTED_GIT_REAL="$(command -v git)"; COUNTED_GIT_LOG="$work/git-calls.log"
export COUNTED_GIT_REAL COUNTED_GIT_LOG
mkdir -p "$work/counted" "$work/scripts"
cat > "$work/counted/git" <<'SCRIPT'
#!/bin/sh
printf '%s\n' "$*" >> "$COUNTED_GIT_LOG"
exec "$COUNTED_GIT_REAL" "$@"
SCRIPT
chmod +x "$work/counted/git"
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
case "\$*" in "worktree list --porcelain") printf 'worktree %s\n' "$work/stub-main" ;; *) exec "$COUNTED_GIT_REAL" "\$@" ;; esac
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

# counted <pattern> <command...>: how many git calls matching the pattern the command makes with
# the counting git first on PATH.
counted() {
  counted_pattern="$1"; shift
  : > "$COUNTED_GIT_LOG"
  (PATH="$work/counted:$PATH"; export PATH; "$@") >/dev/null 2>&1
  grep -c -- "$counted_pattern" "$COUNTED_GIT_LOG"
}
worktree_listings() { counted '^worktree list' "$@"; }

new_repo resolving
app="$(pwd -P)"; other="$(cd "$root/other" && pwd -P)"; nested="$app/nested"
mkdir -p "$nested" "$work/no-repository" && git -C "$nested" init -q

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

echo "main worktree once: how often git is asked"
check "AnswerHandedDownForThisFolder_ListsNoWorktree: a child script in its parent's folder takes the parent's answer" \
  '[ "$(worktree_listings env FLOW_MAIN_WORKTREE="$app" FLOW_MAIN_WORKTREE_FOLDER="$PWD" FLOW_MAIN_WORKTREE_SEARCH_PATH="$work/counted:$PATH" sh "$scripts/three-keys.sh")" = 0 ]'
check "ScriptReadingThreeKeys_ListsTheWorktreesOnce: config reads take the answer found when lib/flow.sh was sourced" \
  '[ "$(worktree_listings sh "$scripts/three-keys.sh")" = 1 ]'
check "CdAndResolveInsideOneScript_ListsTheWorktreesOncePerFolder: a script that moves to another clone and resolves again reads three keys on two listings" \
  '[ "$(worktree_listings sh "$scripts/resolve-after-cd.sh" "$root/other")" = 2 ]'
check "NewTaskWithItsAdapterChildScripts_ListsTheWorktreesAtMostTwice: a flow command and the scripts it starts in its folder share one answer, where each config read once listed them" \
  '[ "$(worktree_listings "$plugin/scripts/new.sh" task "Counted task" --size S --body "$body")" -le 2 ]'
check "NewTaskWithItsAdapterChildScripts_ProbesGitOnce: the git probe is handed down with the main worktree" \
  '[ "$(counted "^--version" "$plugin/scripts/new.sh" task "Probed task" --size S --body "$body")" = 1 ]'
check "GitProgramHandedDown_ProbesNoGit: a child script takes its parent's probe" \
  '[ "$(counted "^--version" env FLOW_GIT_PROGRAM=git sh "$scripts/git-program.sh")" = 0 ]'
check "GitProgramHandedDownThatIsNoKnownGit_IsProbedAgain: only git on PATH or Xcode's git is taken from the environment" \
  '[ "$(env FLOW_GIT_PROGRAM="$work/counted/git" sh "$scripts/git-program.sh")" != "$work/counted/git" ]'
check "GitProgramHandedDownAsXcodesGit_SendsNoCallToTheGitOnPath: a child of a parent that found the shim broken never runs the shim" \
  '[ "$(counted . env FLOW_GIT_PROGRAM="$xcode_git" sh "$scripts/three-keys.sh")" = 0 ]'
check "BrokenGitShimFirstOnPath_SettlesOnXcodesGit: when the git on PATH cannot run, flow takes Xcode's git where it is installed" \
  '[ "$(PATH="$work/broken-git:$PATH" sh "$scripts/git-program.sh")" = "$git_behind_a_broken_shim" ]'

echo "main worktree once: the sandbox"
check "SuiteStartedWithTheHandedDownValues_DoesNotSeeThem: no test inherits a main worktree or a git probe from its caller" \
  '[ -z "$(env FLOW_MAIN_WORKTREE=x FLOW_MAIN_WORKTREE_FOLDER=y FLOW_MAIN_WORKTREE_SEARCH_PATH=z FLOW_GIT_PROGRAM=git sh -c ". \"\$1\"; sandbox_enter \"\$2\" \"\$3\"; printf %s \"\${FLOW_MAIN_WORKTREE-}\${FLOW_MAIN_WORKTREE_FOLDER-}\${FLOW_MAIN_WORKTREE_SEARCH_PATH-}\${FLOW_GIT_PROGRAM-}\"" sandboxed "$plugin/../../tools/lib/sandbox.sh" "$work/inner" "$plugin")" ]'

echo "$fails failed"
[ "$fails" -eq 0 ]
