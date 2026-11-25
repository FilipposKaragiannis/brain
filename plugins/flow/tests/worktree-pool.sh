#!/bin/sh
# worktree-pool.sh: a new item and pool growth, worktree_create and temporary worktrees.
# Takes no argument. Exit 0 when every check passes, 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$P"
work="$(mktemp -d)"
. "$P/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$P"
trap 'sandbox_close $?' EXIT
. "$here/_flow_setup.sh"
echo "new item and pool growth"
mkdir -p "$work/grow" && cd "$work/grow" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t
printf 'hi\n' > README.md && printf 'local\n' > .gitignore && printf 'secret\n' > local && git add -A && git commit -qm init
mkdir -p .flow
printf 'adapters:\n  default: local\nbase: main\npool:\n  # - ../app-wt-1\npool_max: 2\nworktree_copy:\n  - local\nworktree_setup:\n  - printf ran > setup.txt\nnotify:\n  desktop: false\n' > .flow/config.yaml
n1="$(printf '## Problem\nx\n## Acceptance\n- [ ] y\n' | "$P/scripts/new.sh" task "Grow the pool" --size S --body-file -)"
check_all "new: creates through the kind's adapter" '[ "$n1" = "local:task/1" ] && grep -q '\''^## Acceptance'\'' .flow/items/task/1.md'
check "new: bad kind refused" sh -c "! '$P/scripts/new.sh' story 'x' 2>/dev/null"
check "new: empty title refused" sh -c "! '$P/scripts/new.sh' task '' 2>/dev/null"
g1="$("$P/scripts/steward.sh" claim "$n1" 2>/dev/null)"
check_all "claim grows an empty pool" '[ "$g1" = "$(cd ../app-wt-1 && pwd -P)" ] && [ "$(git -C "$g1" symbolic-ref --short HEAD)" = "flow/local-task-1" ]'
check_all "the pool entry is appended, placeholder dropped" '[ "$(yaml_get .flow/config.yaml pool)" = ../app-wt-1 ] && ! grep -q '\''# - ../app-wt-1'\'' .flow/config.yaml && [ "$(yaml_get .flow/config.yaml pool_max)" = 2 ]'
check_all "worktree_copy and worktree_setup ran" '[ "$(cat "$g1/local")" = secret ] && [ "$(cat "$g1/setup.txt")" = ran ]'
n2="$("$P/scripts/new.sh" bug "Second")"
g2="$("$P/scripts/steward.sh" claim "$n2" 2>/dev/null)"
check_all "a grown worktree keeps its idle branch for when it is free" '[ "$(git rev-parse --verify -q refs/heads/main-wt-1)" = "$(git rev-parse main)" ]'
check_all "a second claim grows again, named after the last entry" '[ "$g2" = "$(cd ../app-wt-2 && pwd -P)" ] && [ "$(yaml_get .flow/config.yaml pool | wc -l | tr -d '\'' '\'')" = 2 ]'
n3="$("$P/scripts/new.sh" task "Third")"
"$P/scripts/steward.sh" claim "$n3" >/dev/null 2>&1; code=$?
check_all "at pool_max the claim fails (exit 3)" '[ "$code" -eq 3 ] && [ ! -d ../app-wt-3 ]'
rm "$g2/setup.txt"
check "setup re-runs on demand" sh -c "'$P/scripts/steward.sh' setup '$g2' >/dev/null && [ -f '$g2/setup.txt' ]"
"$P/scripts/steward.sh" add >/dev/null 2>&1
check_all "add without a path takes the next name" '[ -d ../app-wt-3 ] && [ "$(yaml_get .flow/config.yaml pool | tail -1)" = ../app-wt-3 ]'
rm -rf ../app-wt-3
g3="$("$P/scripts/steward.sh" claim "$n3" 2>"$work/recreate.err")"; code=$?
check_all "claim takes a pool path missing on disk (git still lists it) as free and recreates it" '[ "$code" -eq 0 ] && [ "$g3" = "$(cd ../app-wt-3 && pwd -P)" ] && [ "$(git -C "$g3" symbolic-ref --short HEAD)" = "flow/$(item_slug "$n3")" ] && grep -q "recreated app-wt-3, which was missing on disk, on main-wt-3 at main" "$work/recreate.err"'
check_all "the recreated worktree starts on its idle branch at the base tip, set up, its pool entry not repeated" '[ "$(git rev-parse --verify -q refs/heads/main-wt-3)" = "$(git rev-parse main)" ] && [ "$(cat "$g3/setup.txt")" = ran ] && [ "$(cat "$g3/local")" = secret ] && [ "$(grep -c app-wt-3 .flow/config.yaml)" = 1 ]'
rm "$g3/setup.txt" && "$P/scripts/steward.sh" release "$n3" >/dev/null 2>&1 && git worktree remove --force ../app-wt-3
"$P/scripts/steward.sh" add ../app-wt-3 > "$work/recreate.out" 2>&1; code=$?
check_all "add recreates a pool path missing on disk in place, without a second pool entry" '[ "$code" -eq 0 ] && [ "$(git -C ../app-wt-3 symbolic-ref --short HEAD)" = main-wt-3 ] && [ "$(git -C ../app-wt-3 rev-parse HEAD)" = "$(git rev-parse main)" ] && [ "$(grep -c app-wt-3 .flow/config.yaml)" = 1 ] && grep -q "recreated ../app-wt-3, already in the pool" "$work/recreate.out"'
"$P/scripts/steward.sh" claim "$n3" >/dev/null 2>&1
sed -i.bak 's|^  - ../app-wt-3$|&\
  - ../trees/app-wt-4|' .flow/config.yaml && rm -f .flow/config.yaml.bak
n4="$("$P/scripts/new.sh" task "Fourth")"
g4="$("$P/scripts/steward.sh" claim "$n4" 2>/dev/null)"; code=$?
check_all "claim recreates a pool path whose parent folder is missing too and prints it without .." '[ "$code" -eq 0 ] && [ -d ../trees/app-wt-4 ] && [ "$g4" = "$(cd ../trees/app-wt-4 && pwd -P)" ] && ! printf "%s" "$g4" | grep -qF .. && [ "$("$P/scripts/steward.sh" find "$n4")" = "$g4" ]'

echo "worktree_create"
mkdir -p "$work/create" && cd "$work/create" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t
printf 'hi\n' > README.md && printf 'local\n' > .gitignore && printf 'secret\n' > local && git add -A && git commit -qm init
mkdir -p .flow
cat > "$work/create/fake-create.sh" <<EOF
#!/bin/sh
echo "fake create made \$1"
[ "\$2" = main ] || { echo "fake create refuses the base \$2"; exit 1; }
git -C "$PWD" worktree add -q --detach "\$1" "\$2"
EOF
cat > "$work/create/failing-create.sh" <<EOF
#!/bin/sh
echo "refused: folder not empty"
exit 4
EOF
cat > "$work/create/idle-create.sh" <<EOF
#!/bin/sh
exit 0
EOF
write_create_config() { printf 'adapters:\n  default: local\nbase: main\npool:\n%bpool_max: 9\nworktree_name: %s\nworktree_create: %s\nworktree_copy:\n  - local\nworktree_setup:\n  - printf ran > setup.txt\nnotify:\n  desktop: false\n' "$1" "$2" "$3" > .flow/config.yaml; }
fake_create="sh $work/create/fake-create.sh {path} {base}"
write_create_config '' "../{repo} 'q-wt-{n}" "$fake_create"
grown_item="$("$P/scripts/new.sh" task "Create")"
grown_worktree_path="$("$P/scripts/steward.sh" claim "$grown_item" 2>"$work/create.err")"; code=$?
grown_pool_path="$(cd .. && pwd -P)/app 'q-wt-1"
check "CreateCommandRefusingAnyBaseButBaseBranch_ClaimExitsZero: claim grows the pool through a command that refuses any {base} but the base branch, so the command got the base branch" [ "$code" -eq 0 ]
check "CreateCommandOnPoolGrowth_MakesWorktreeAtQuotedPath: claim grows the pool through worktree_create, which gets a path with a space and a quote as one argument and makes the worktree there" [ "$(git -C "$grown_pool_path" rev-parse --show-toplevel 2>/dev/null)" = "$grown_pool_path" ]
check "CreateCommandPrintingToStdout_ClaimPrintsPathAlone: claim prints the path alone though the command prints to stdout" [ "$grown_worktree_path" = "$grown_pool_path" ]
check "CreateCommandOutput_ReachesClaimStderr: the command's own output reaches the claim's stderr" grep -q "fake create made" "$work/create.err"
check "CreatedPoolWorktree_GetsPoolEntry: the created worktree's pool entry is appended" [ "$(yaml_get .flow/config.yaml pool)" = "../app 'q-wt-1" ]
check "CreatedPoolWorktree_MakesIdleBranchAtBaseTip: the created worktree's idle branch is made at the base tip" [ "$(git rev-parse --verify -q refs/heads/main-wt-1)" = "$(git rev-parse main)" ]
check "CreatedPoolWorktree_GetsWorktreeCopyFiles: worktree_copy copies its files into the created worktree" [ "$(cat "$grown_worktree_path/local")" = secret ]
check "CreatedPoolWorktree_RunsWorktreeSetup: worktree_setup runs in the created worktree" [ "$(cat "$grown_worktree_path/setup.txt")" = ran ]
added_pool_path="../app 'q-wt-2"
"$P/scripts/steward.sh" add > "$work/create.out" 2>&1; code=$?
check "AddWithNoPathAndCreateCommand_ExitsZero: add with no path succeeds through the command" [ "$code" -eq 0 ]
check "AddWithNoPathAndCreateCommand_MakesWorktreeAtNextPath: add with no path has the command make the worktree at the next pool path" [ "$(git -C "$added_pool_path" rev-parse --show-toplevel 2>/dev/null)" = "$(cd .. && pwd -P)/app 'q-wt-2" ]
check "AddWithNoPathAndCreateCommand_AppendsPoolEntry: add with no path appends the made worktree's pool entry" [ "$(yaml_get .flow/config.yaml pool | tail -1)" = "$added_pool_path" ]
git worktree remove --force "$added_pool_path"
"$P/scripts/steward.sh" add "$added_pool_path" > "$work/create.out" 2>&1; code=$?
check "AddOfMissingPoolPathWithCreateCommand_ExitsZero: add of a pool path missing on disk succeeds through the command" [ "$code" -eq 0 ]
check "AddOfMissingPoolPathWithCreateCommand_RecreatesWorktree: add has the command make a worktree again at a pool path missing on disk" [ "$(git -C "$added_pool_path" rev-parse --show-toplevel 2>/dev/null)" = "$(cd .. && pwd -P)/app 'q-wt-2" ]
check "AddOfMissingPoolPathWithCreateCommand_PutsItOnIdleBranch: add puts the recreated worktree on its idle branch" [ "$(git -C "$added_pool_path" symbolic-ref --short HEAD)" = main-wt-2 ]
write_create_config "  - ../app'q-wt-5\n" "../{repo} 'q-wt-{n}" "$fake_create"
recreated_item="$("$P/scripts/new.sh" task "Recreate")"
recreated_worktree_path="$("$P/scripts/steward.sh" claim "$recreated_item" 2>"$work/create.err")"; code=$?
check "ClaimOfMissingPoolPathWithCreateCommand_ExitsZero: claim of a pool path missing on disk succeeds through the command" [ "$code" -eq 0 ]
recreated_pool_path="$(cd .. && pwd -P)/app'q-wt-5"
check "ClaimOfMissingPoolPathWithCreateCommand_RecreatesWorktree: claim has the command make a worktree again at a pool path missing on disk" [ "$(git -C "$recreated_pool_path" rev-parse --show-toplevel 2>/dev/null)" = "$recreated_pool_path" ]
check "ClaimOfMissingPoolPathWithCreateCommand_PrintsThatPath: claim prints the recreated pool path as the claimed worktree" [ "$recreated_worktree_path" = "$recreated_pool_path" ]
check "ClaimRecreateWithCreateCommand_NamesIdleBranch: the recreate names the idle branch the worktree was put on" grep -q "main-wt-5" "$work/create.err"
check "ClaimRecreateWithCreateCommand_MakesIdleBranchAtBaseTip: the recreated worktree's idle branch is made at the base tip before the claim moves it to the item's branch" [ "$(git rev-parse --verify -q refs/heads/main-wt-5)" = "$(git rev-parse main)" ]
write_create_config '' '../{repo}-fail-wt-{n}' "sh $work/create/failing-create.sh {path} {base}"
refused_item="$("$P/scripts/new.sh" task "Refused")"
"$P/scripts/steward.sh" claim "$refused_item" > "$work/create.out" 2>"$work/create.err"; code=$?
check "FailingCreateCommandOnClaim_ExitsOne: a failing command fails the claim with exit 1, not the full pool's 3" [ "$code" = 1 ]
check "FailingCreateCommandOnClaim_PassesItsOutputOn: a failing command's output reaches the claim's stderr" grep -q 'refused: folder not empty' "$work/create.err"
check "FailingCreateCommandOnClaim_NamesWorktreeCreate: a failing claim names worktree_create as what failed" grep -q 'worktree_create failed' "$work/create.err"
check_all "FailingCreateCommandOnClaim_IsNotBlamedOnPoolMax: a failing command is not blamed on pool_max" '! grep -q pool_max "$work/create.err"'
check "FailingCreateCommandOnClaim_AddsNoPoolEntry: a claim whose command fails adds no pool entry" [ -z "$(yaml_get .flow/config.yaml pool)" ]
"$P/scripts/steward.sh" add > "$work/create.out" 2>&1; code=$?
check "FailingCreateCommandOnAdd_ExitsOne: add with a failing command exits 1" [ "$code" = 1 ]
check "FailingCreateCommandOnAdd_PassesItsOutputOn: add with a failing command passes its output on" grep -q 'refused: folder not empty' "$work/create.out"
check "FailingCreateCommandOnAdd_AddsNoPoolEntry: add with a failing command adds no pool entry" [ -z "$(yaml_get .flow/config.yaml pool)" ]
write_create_config '' '../{repo}-idle-wt-{n}' "sh $work/create/idle-create.sh {path} {base}"
"$P/scripts/steward.sh" claim "$refused_item" > "$work/create.out" 2>&1; code=$?
check "CreateCommandMakingNoWorktree_FailsClaimWithExitOne: a command that exits 0 but makes no worktree fails the claim with exit 1" [ "$code" = 1 ]
check "CreateCommandMakingNoWorktree_AddsNoPoolEntry: a command that makes no worktree adds no pool entry" [ -z "$(yaml_get .flow/config.yaml pool)" ]
cat > "$work/create/foreign-create.sh" <<'EOF'
#!/bin/sh
git init -q "$1"
EOF
write_create_config '' '../{repo}-foreign-wt-{n}' "sh $work/create/foreign-create.sh {path} {base}"
"$P/scripts/steward.sh" claim "$refused_item" > "$work/create.out" 2>&1; code=$?
check "CreateCommandMakingForeignRepository_FailsClaimWithExitOne: a command that makes a repository of its own, not a worktree of this one, fails the claim with exit 1" [ "$code" = 1 ]
check "CreateCommandMakingForeignRepository_AddsNoPoolEntry: a command that makes a repository of its own adds no pool entry" [ -z "$(yaml_get .flow/config.yaml pool)" ]
write_create_config '' '../{repo}-bare-wt-{n}' "sh $work/create/fake-create.sh ../app-bare-made {base}"
"$P/scripts/steward.sh" claim "$refused_item" > "$work/create.out" 2>&1; code=$?
check "CreateCommandWithoutPath_ExitsTwo: one with no {path} is refused, exit 2" [ "$code" = 2 ]
check "CreateCommandWithoutPath_NamesKey: the refusal names worktree_create" grep -q "worktree_create has no {path}" "$work/create.out"
check "CreateCommandWithoutPath_MakesNoWorktree: one with no {path} never runs, so the worktree it names never appears" [ ! -e ../app-bare-made ]
kept_tip="$(git commit-tree -p main -m kept "$(git rev-parse 'main^{tree}')")"
git update-ref refs/heads/main-wt-1 "$kept_tip"
write_create_config '' '../{repo}-kept-wt-{n}' "$fake_create"
"$P/scripts/steward.sh" add > "$work/create.out" 2>&1; code=$?
check "CreatedPoolWorktreeWhoseIdleBranchHasOwnCommits_ExitsZero: add succeeds though the idle branch has commits of its own" [ "$code" -eq 0 ]
check_all "CreatedPoolWorktreeWhoseIdleBranchHasOwnCommits_StartsDetached: the created worktree is on no branch when its idle branch has commits of its own, so those commits are not moved" '! git -C ../app-kept-wt-1 symbolic-ref -q HEAD'
check "CreatedPoolWorktreeWhoseIdleBranchHasOwnCommits_StartsAtBaseTip: the created worktree starts at the base tip though its idle branch has commits of its own" [ "$(git -C ../app-kept-wt-1 rev-parse HEAD)" = "$(git rev-parse main)" ]
check "CreatedPoolWorktreeWhoseIdleBranchHasOwnCommits_KeepsThoseCommits: an idle branch with commits of its own keeps them" [ "$(git rev-parse main-wt-1)" = "$kept_tip" ]
write_create_config '' '../{repo}&a|b\c$HOME-wt-{n}' "$fake_create"
"$P/scripts/steward.sh" add > "$work/create.out" 2>&1
shell_characters_path="$(cd .. && pwd -P)/app&a|b\\c\$HOME-wt-1"
check "PathWithShellCharacters_GetsWorktreeAtThatLiteralPath: a path holding & | \\ and \$ reaches the command as itself, so the worktree sits at that literal folder" [ "$(git -C "$shell_characters_path" rev-parse --show-toplevel 2>/dev/null)" = "$shell_characters_path" ]
cdpath_decoy="$work/create/cdpath-decoy"
mkdir -p "$cdpath_decoy/.git"
write_create_config '' '../{repo}-cdpath-wt-{n}' "$fake_create"
CDPATH="$cdpath_decoy" "$P/scripts/steward.sh" add > "$work/create.out" 2>&1; code=$?
check "CreateCommandUnderCdpathWithDecoyGitFolder_ExitsZero: a CDPATH holding a decoy .git folder does not make the created worktree look foreign" [ "$code" -eq 0 ]
check "CreateCommandUnderCdpathWithDecoyGitFolder_AppendsPoolEntry: a CDPATH holding a decoy .git folder does not make the created worktree look foreign, so its pool entry is appended" [ "$(yaml_get .flow/config.yaml pool)" = ../app-cdpath-wt-1 ]
write_create_config '' '../{repo}-lenient-wt-{n}' 'git worktree add -q --detach {path} {base} 2>/dev/null || test -d {path}'
"$P/scripts/steward.sh" add > "$work/create.out" 2>&1
"$P/scripts/steward.sh" add ../app-lenient-wt-1 > "$work/create.out" 2>&1; code=$?
check "AddOfExistingPoolWorktreeWithLenientCreateCommand_ExitsTwo: add of a pool worktree already on disk is refused before a command that tolerates an existing folder runs, exit 2" [ "$code" = 2 ]
check "AddOfExistingPoolWorktreeWithLenientCreateCommand_AddsNoPoolEntry: the refused add leaves the pool its one entry" [ "$(yaml_get .flow/config.yaml pool)" = ../app-lenient-wt-1 ]
"$P/scripts/steward.sh" add "$(pwd -P)" > "$work/create.out" 2>&1; code=$?
check "AddOfMainWorktreeWithLenientCreateCommand_ExitsTwo: add of the main worktree is refused before a command that tolerates an existing folder runs, exit 2" [ "$code" = 2 ]
check "AddOfMainWorktreeWithLenientCreateCommand_AddsNoPoolEntry: the refused add puts no main worktree entry in the pool" [ "$(yaml_get .flow/config.yaml pool)" = ../app-lenient-wt-1 ]
check "AddOfMainWorktreeWithLenientCreateCommand_KeepsMainBranch: the main worktree stays on its branch" [ "$(git symbolic-ref --short HEAD)" = main ]
ln -s "$work/create/dangling-target" ../app-dangling-wt-1
write_create_config "  - ../app-dangling-wt-1\n" '../{repo}-dangling-wt-{n}' "$fake_create"
dangling_item="$("$P/scripts/new.sh" task "Dangling")"
"$P/scripts/steward.sh" claim "$dangling_item" > "$work/create.out" 2>&1; code=$?
check "ClaimOfDanglingSymlinkPoolPathWithCreateCommand_ExitsTwo: a claim that meets a dangling symlink at a pool path refuses before the command runs, exit 2" [ "$code" = 2 ]
rm ../app-dangling-wt-1

echo "temporary worktrees"
mkdir -p "$work/temporary-worktrees" && cd "$work/temporary-worktrees" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t
printf 'hi\n' > README.md && git add -A && git commit -qm init
git worktree add -q --detach ../app-wt-1 && mkdir -p .flow
cat > "$work/temporary-worktrees/failing-create.sh" <<EOF
#!/bin/sh
echo "refused: folder not empty"
exit 4
EOF
cat > "$work/temporary-worktrees/folder-remove.sh" <<EOF
#!/bin/sh
rm -rf "\$1"
EOF
cat > "$work/temporary-worktrees/failing-remove.sh" <<EOF
#!/bin/sh
echo "refused: worktree busy"
exit 5
EOF
cat > "$work/temporary-worktrees/idle-remove.sh" <<EOF
#!/bin/sh
exit 0
EOF
cat > "$work/temporary-worktrees/git-remove.sh" <<EOF
#!/bin/sh
git -C "$PWD" worktree remove --force "\$1"
EOF
write_temporary_config() { printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../app-wt-1\n%bnotify:\n  desktop: false\n' "$1" > .flow/config.yaml; }
fake_temporary_create="worktree_create: sh $work/temporary-worktrees/fake-create.sh {path} {base}\n"
write_temporary_config ''
phases_item="$("$P/scripts/new.sh" task "Phases")"
task_worktree_path="$("$P/scripts/steward.sh" claim "$phases_item" 2>/dev/null)"
git -C "$task_worktree_path" commit -q --allow-empty -m "task work"
temporary_slug="$(item_slug "$phases_item")"
cat > "$work/temporary-worktrees/fake-create.sh" <<EOF
#!/bin/sh
echo "fake create made \$1"
[ "\$2" = "flow/$temporary_slug" ] || { echo "fake create refuses the base \$2"; exit 1; }
git -C "$PWD" worktree add -q --detach "\$1" "\$2"
EOF
plain_phase_worktree="$("$P/scripts/steward.sh" tmp add "$phases_item" phase-1 2>/dev/null)"; code=$?
temporary_folder="$(pwd -P)/.flow/tmp"
check "TmpAddOfNewPhase_ExitsZero: tmp add of a new phase succeeds" [ "$code" -eq 0 ]
check "TmpAddOfNewPhase_PrintsPathAlone: tmp add prints the temporary worktree's path alone" [ "$(cd "$plain_phase_worktree" 2>/dev/null && pwd -P)" = "$temporary_folder/$temporary_slug-phase-1" ]
check "TmpAddOfNewPhase_PutsWorktreeOnPhaseBranch: the temporary worktree is on the phase's branch" [ "$(git -C "$plain_phase_worktree" symbolic-ref --short HEAD)" = "flow/$temporary_slug-phase-1" ]
check "TmpAddOfNewPhase_StartsPhaseBranchAtTaskTip: the phase's branch starts at the task branch's tip" [ "$(git -C "$plain_phase_worktree" rev-parse HEAD)" = "$(git rev-parse "flow/$temporary_slug")" ]
"$P/scripts/steward.sh" tmp remove "$plain_phase_worktree" > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpRemoveOfCleanWorktree_ExitsZero: tmp remove of a clean temporary worktree succeeds" [ "$code" -eq 0 ]
check "TmpRemoveOfCleanWorktree_RemovesFolder: tmp remove removes the temporary worktree's folder" [ ! -e "$plain_phase_worktree" ]
check_all "TmpRemoveOfCleanWorktree_DeletesPhaseBranch: tmp remove deletes the phase's branch" '! git rev-parse --verify -q "refs/heads/flow/$temporary_slug-phase-1"'
dirty_phase_worktree="$("$P/scripts/steward.sh" tmp add "$phases_item" phase-2 2>/dev/null)"
printf 'wip\n' > "$dirty_phase_worktree/wip.txt"
"$P/scripts/steward.sh" tmp remove "$dirty_phase_worktree" > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpRemoveOfDirtyWorktree_ExitsThree: a temporary worktree with uncommitted changes is refused, exit 3" [ "$code" = 3 ]
check "TmpRemoveOfDirtyWorktree_KeepsChanges: a refused temporary worktree keeps its changes on disk" [ -f "$dirty_phase_worktree/wip.txt" ]
write_temporary_config "$fake_temporary_create"
created_phase_worktree="$("$P/scripts/steward.sh" tmp add "$phases_item" phase-3 2>"$work/temporary-worktrees.err")"; code=$?
check "TmpAddWithCreateCommandRefusingAnyBaseButTaskBranch_ExitsZero: tmp add succeeds through a command that refuses any {base} but the task branch, so the command got the task branch" [ "$code" -eq 0 ]
check "TmpAddWithCreateCommand_MakesWorktreeAtPhasePath: the command gets the temporary worktree's path as {path} and makes the worktree there" [ "$(git -C "$temporary_folder/$temporary_slug-phase-3" rev-parse --show-toplevel 2>/dev/null)" = "$temporary_folder/$temporary_slug-phase-3" ]
check "TmpAddWithCreateCommandPrintingToStdout_PrintsPathAlone: tmp add prints the path alone though the command prints to stdout" [ "$(cd "$created_phase_worktree" && pwd -P)" = "$temporary_folder/$temporary_slug-phase-3" ]
check "TmpAddWithCreateCommand_PassesItsOutputToStderr: the command's own output reaches stderr" grep -q "fake create made" "$work/temporary-worktrees.err"
check "TmpAddWithCreateCommand_PutsWorktreeOnPhaseBranch: the made worktree is put on the phase's branch" [ "$(git -C "$created_phase_worktree" symbolic-ref --short HEAD)" = "flow/$temporary_slug-phase-3" ]
check "TmpAddWithCreateCommand_StartsPhaseBranchAtTaskTip: the phase's branch starts at the task branch's tip" [ "$(git -C "$created_phase_worktree" rev-parse HEAD)" = "$(git rev-parse "flow/$temporary_slug")" ]
write_temporary_config "worktree_create: sh $work/temporary-worktrees/failing-create.sh {path} {base}\n"
"$P/scripts/steward.sh" tmp add "$phases_item" phase-4 > "$work/temporary-worktrees.out" 2>"$work/temporary-worktrees.err"; code=$?
check "TmpAddWithFailingCreateCommand_ExitsOne: a failing command fails the add with exit 1" [ "$code" = 1 ]
check "TmpAddWithFailingCreateCommand_PassesItsOutputOn: a failing command's output reaches stderr" grep -q 'refused: folder not empty' "$work/temporary-worktrees.err"
check "TmpAddWithFailingCreateCommand_PrintsNoPath: a failing add prints no path" [ ! -s "$work/temporary-worktrees.out" ]
write_temporary_config "${fake_temporary_create}worktree_remove: sh $work/temporary-worktrees/folder-remove.sh {path}\n"
"$P/scripts/steward.sh" tmp remove "$created_phase_worktree" > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpRemoveWithRemoveCommand_ExitsZero: tmp remove through the command succeeds" [ "$code" -eq 0 ]
check "TmpRemoveWithRemoveCommand_RemovesFolder: the command gets the temporary worktree's path as {path}, so the folder it removes is that worktree's" [ ! -e "$created_phase_worktree" ]
check_all "TmpRemoveWithRemoveCommand_PrunesGitRecord: git keeps no record of the removed worktree" '! git worktree list --porcelain | grep -qF "$temporary_slug-phase-3"'
check_all "TmpRemoveWithRemoveCommand_DeletesPhaseBranch: tmp remove deletes the phase's branch" '! git rev-parse --verify -q "refs/heads/flow/$temporary_slug-phase-3"'
write_temporary_config "${fake_temporary_create}worktree_remove: sh $work/temporary-worktrees/git-remove.sh {path}\n"
record_cleared_phase_worktree="$("$P/scripts/steward.sh" tmp add "$phases_item" record-cleared 2>/dev/null)"
"$P/scripts/steward.sh" tmp remove "$record_cleared_phase_worktree" > "$work/temporary-worktrees.out" 2>&1; code=$?
check "RemoveCommandClearingGitRecord_ExitsZero: a command that removes git's record itself still makes tmp remove succeed" [ "$code" = 0 ]
check "RemoveCommandClearingGitRecord_RemovesFolder: a command that removes the worktree through git worktree remove takes the folder as a plain rm would, since flow passes it the worktree's path" [ ! -e "$record_cleared_phase_worktree" ]
check_all "RemoveCommandClearingGitRecord_LeavesNoGitRecord: git keeps no record of the removed worktree" '! git worktree list --porcelain | grep -qF "$temporary_slug-record-cleared"'
check_all "RemoveCommandClearingGitRecord_DeletesPhaseBranch: tmp remove deletes the phase's branch" '! git rev-parse --verify -q "refs/heads/flow/$temporary_slug-record-cleared"'
kept_phase_worktree="$("$P/scripts/steward.sh" tmp add "$phases_item" phase-5 2>/dev/null)"
write_temporary_config "${fake_temporary_create}worktree_remove: sh $work/temporary-worktrees/failing-remove.sh {path}\n"
"$P/scripts/steward.sh" tmp remove "$kept_phase_worktree" > "$work/temporary-worktrees.out" 2>"$work/temporary-worktrees.err"; code=$?
check "TmpRemoveWithFailingRemoveCommand_ExitsOne: a failing command fails the remove with exit 1" [ "$code" = 1 ]
check "TmpRemoveWithFailingRemoveCommand_PassesItsOutputOn: a failing command's output reaches stderr" grep -q 'refused: worktree busy' "$work/temporary-worktrees.err"
check "TmpRemoveWithFailingRemoveCommand_KeepsPhaseBranch: a failing remove keeps the phase's branch" git rev-parse --verify -q "refs/heads/flow/$temporary_slug-phase-5"
write_temporary_config "${fake_temporary_create}worktree_remove: sh $work/temporary-worktrees/idle-remove.sh {path}\n"
"$P/scripts/steward.sh" tmp remove "$kept_phase_worktree" > "$work/temporary-worktrees.out" 2>"$work/temporary-worktrees.err"; code=$?
check "RemoveCommandLeavingFolder_FailsRemoveWithExitOne: a command that exits 0 but leaves the folder fails the remove with exit 1" [ "$code" = 1 ]
check "RemoveCommandLeavingFolder_KeepsFolder: a remove whose command leaves the folder keeps it" [ -d "$kept_phase_worktree" ]
check "RemoveCommandLeavingFolder_KeepsPhaseBranch: a remove that leaves the folder keeps the phase's branch" git rev-parse --verify -q "refs/heads/flow/$temporary_slug-phase-5"
write_temporary_config "${fake_temporary_create}worktree_remove: sh $work/temporary-worktrees/folder-remove.sh $kept_phase_worktree\n"
"$P/scripts/steward.sh" tmp remove "$kept_phase_worktree" > "$work/temporary-worktrees.out" 2>&1; code=$?
check "RemoveCommandWithoutPath_ExitsTwo: one with no {path} is refused, exit 2" [ "$code" = 2 ]
check "RemoveCommandWithoutPath_NamesKey: the refusal names worktree_remove" grep -q "worktree_remove has no {path}" "$work/temporary-worktrees.out"
check "RemoveCommandWithoutPath_KeepsFolder: one with no {path} never runs, so the folder it names stays" [ -d "$kept_phase_worktree" ]
check_all "RemoveCommandWithoutPath_KeepsGitRecord: git still lists the worktree" 'git worktree list --porcelain | grep -qF "$temporary_slug-phase-5"'
write_temporary_config "${fake_temporary_create}worktree_remove: sh $work/temporary-worktrees/folder-remove.sh {path}\n"
"$P/scripts/steward.sh" tmp remove . > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpRemoveOfDotInMainWorktree_ExitsTwo: . run in the main worktree is the main worktree, refused" [ "$code" = 2 ]
check "TmpRemoveOfDotInMainWorktree_KeepsMainWorktree: the remove command never runs on the main worktree" [ -f README.md ]
"$P/scripts/steward.sh" tmp remove "$(pwd -P)" > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpRemoveOfMainWorktree_ExitsTwo: the main worktree's absolute path is refused" [ "$code" = 2 ]
check "TmpRemoveOfMainWorktree_KeepsMainWorktree: the remove command never runs on the main worktree" [ -f README.md ]
mkdir -p "$work/temporary-worktrees/plain"
"$P/scripts/steward.sh" tmp remove "$work/temporary-worktrees/plain" > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpRemoveOfPlainFolder_ExitsTwo: a folder that is no worktree is refused" [ "$code" = 2 ]
check "TmpRemoveOfPlainFolder_KeepsFolder: the remove command never runs on a folder that is no worktree" [ -d "$work/temporary-worktrees/plain" ]
"$P/scripts/steward.sh" tmp remove "" > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpRemoveOfEmptyPath_ExitsTwo: an empty path is refused" [ "$code" = 2 ]
"$P/scripts/steward.sh" tmp remove ../app-wt-1 > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpRemoveOfPoolWorktree_ExitsTwo: a pool worktree is refused" [ "$code" = 2 ]
check "TmpRemoveOfPoolWorktree_KeepsPoolWorktree: the remove command never runs on a pool worktree" [ -d ../app-wt-1 ]
write_temporary_config ''
"$P/scripts/steward.sh" tmp remove ../app-wt-1 > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpRemoveOfPoolWorktreeWithoutRemoveCommand_ExitsTwo: a pool worktree is refused when git does the remove too" [ "$code" = 2 ]
"$P/scripts/steward.sh" tmp remove "$work/temporary-worktrees/plain" > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpRemoveOfPlainFolderWithoutRemoveCommand_ExitsTwo: a folder that is no worktree is refused when git does the remove" [ "$code" = 2 ]
write_temporary_config "${fake_temporary_create}worktree_remove: sh $work/temporary-worktrees/folder-remove.sh {path}\n"
relative_phase_worktree="$("$P/scripts/steward.sh" tmp add "$phases_item" phase-6 2>/dev/null)"
"$P/scripts/steward.sh" tmp remove ".flow/tmp/$temporary_slug-phase-6" > "$work/temporary-worktrees.out" 2>&1
check "TmpRemoveOfRelativePath_RemovesThatWorktree: a path relative to where tmp remove runs names the worktree removed" [ ! -e "$relative_phase_worktree" ]
hidden_untracked_phase_worktree="$("$P/scripts/steward.sh" tmp add "$phases_item" hidden-untracked 2>/dev/null)"
printf 'wip\n' > "$hidden_untracked_phase_worktree/wip.txt"
git config status.showUntrackedFiles no
"$P/scripts/steward.sh" tmp remove "$hidden_untracked_phase_worktree" > "$work/temporary-worktrees.out" 2>&1; code=$?
git config --unset status.showUntrackedFiles
check "TmpRemoveOfUntrackedFileHiddenByStatusConfig_ExitsThree: an untracked file counts as uncommitted though status.showUntrackedFiles=no hides it from git status, exit 3" [ "$code" = 3 ]
check "TmpRemoveOfUntrackedFileHiddenByStatusConfig_KeepsFile: the remove command never runs, so the untracked file stays" [ -f "$hidden_untracked_phase_worktree/wip.txt" ]
write_temporary_config "worktree_create: sh $work/temporary-worktrees/fake-create.sh \"{path}\" {base}\n"
"$P/scripts/steward.sh" tmp add "$phases_item" quoted > "$work/temporary-worktrees.out" 2>&1; code=$?
check "CreateCommandQuotingPath_ExitsTwo: a template with {path} inside double quotes is refused" [ "$code" = 2 ]
check "CreateCommandQuotingPath_MakesNoWorktree: the refused command never runs, so the phase's folder never appears" [ ! -e "$temporary_folder/$temporary_slug-quoted" ]
write_temporary_config "worktree_create: sh $work/temporary-worktrees/fake-create.sh '{path}' {base}\n"
"$P/scripts/steward.sh" tmp add "$phases_item" phase-7 > "$work/temporary-worktrees.out" 2>&1; code=$?
check "CreateCommandSingleQuotingPath_ExitsTwo: a template with {path} inside single quotes is refused" [ "$code" = 2 ]
write_temporary_config "worktree_create: sh $work/temporary-worktrees/fake-create.sh \\\\{path} {base}\n"
"$P/scripts/steward.sh" tmp add "$phases_item" escaped > "$work/temporary-worktrees.out" 2>&1; code=$?
check "CreateCommandEscapingPath_ExitsTwo: a template with {path} after a backslash is refused" [ "$code" = 2 ]
write_temporary_config 'worktree_create: touch {path}.ran; echo "$(dirname "{path}")"\n'
"$P/scripts/steward.sh" tmp add "$phases_item" substituted > "$work/temporary-worktrees.out" 2>&1; code=$?
check "CreateCommandQuotingPathInQuotedSubstitution_ExitsTwo: a template with {path} quoted inside a quoted \$(...) is refused, as sh would split the path there" [ "$code" = 2 ]
check "CreateCommandQuotingPathInQuotedSubstitution_RunsNothing: the refused command never runs, so its marker never appears" [ ! -e "$temporary_folder/$temporary_slug-substituted.ran" ]
write_temporary_config 'worktree_create: touch {path}.ran; echo "$(printf %s " {path}")"\n'
"$P/scripts/steward.sh" tmp add "$phases_item" split > "$work/temporary-worktrees.out" 2>&1; code=$?
check "CreateCommandQuotingPathAfterQuoteInSubstitution_ExitsTwo: a template with {path} inside a quoted string that a quoted \$(...) opens is refused, as sh would split the path there" [ "$code" = 2 ]
check "CreateCommandQuotingPathAfterQuoteInSubstitution_RunsNothing: the refused command never runs, so its marker never appears" [ ! -e "$temporary_folder/$temporary_slug-split.ran" ]
write_temporary_config 'worktree_create: touch {path}.ran; echo "`dirname "{path}"`"\n'
"$P/scripts/steward.sh" tmp add "$phases_item" backticked > "$work/temporary-worktrees.out" 2>&1; code=$?
check "CreateCommandQuotingPathInQuotedBackticks_ExitsTwo: a template with {path} quoted inside quoted backticks is refused, as sh would split the path there" [ "$code" = 2 ]
write_temporary_config 'worktree_create: touch {path}.ran; rm -rf "`cd \\"{path}\\" && pwd`"\n'
"$P/scripts/steward.sh" tmp add "$phases_item" escaped-backticked > "$work/temporary-worktrees.out" 2>&1; code=$?
check "CreateCommandEscapingQuotesAroundPathInQuotedBackticks_ExitsTwo: a template with {path} between escaped quotes inside quoted backticks is refused, as sh drops those backslashes and would split the path there" [ "$code" = 2 ]
check "CreateCommandEscapingQuotesAroundPathInQuotedBackticks_RunsNothing: the refused command never runs, so its marker never appears" [ ! -e "$temporary_folder/$temporary_slug-escaped-backticked.ran" ]
write_temporary_config 'worktree_create: touch {path}.ran; echo `basename {path}`\n'
"$P/scripts/steward.sh" tmp add "$phases_item" bare-backticked > "$work/temporary-worktrees.out" 2>&1; code=$?
check "CreateCommandWithBarePathInBackticks_ExitsTwo: a template with {path} anywhere inside backticks is refused, as backticks cannot quote it" [ "$code" = 2 ]
check "CreateCommandWithBarePathInBackticks_RunsNothing: the refused command never runs, so its marker never appears" [ ! -e "$temporary_folder/$temporary_slug-bare-backticked.ran" ]
write_temporary_config "worktree_create: echo \"\$(date)\" > /dev/null; sh $work/temporary-worktrees/fake-create.sh {path} {base}\n"
"$P/scripts/steward.sh" tmp add "$phases_item" beside-substitution > "$work/temporary-worktrees.out" 2>&1
check "CreateCommandWithBarePathBesideQuotedSubstitution_MakesWorktree: a quoted \$(...) that closes before a bare {path} leaves the path unquoted, so the command runs and makes the worktree" [ "$(git -C "$temporary_folder/$temporary_slug-beside-substitution" rev-parse --show-toplevel 2>/dev/null)" = "$temporary_folder/$temporary_slug-beside-substitution" ]
write_temporary_config "worktree_create: printf %s '\$(' > /dev/null; sh $work/temporary-worktrees/fake-create.sh {path} {base}\n"
"$P/scripts/steward.sh" tmp add "$phases_item" after-quoted-opener > "$work/temporary-worktrees.out" 2>&1
check "CreateCommandWithBarePathAfterSingleQuotedOpener_MakesWorktree: a \$( inside single quotes opens no substitution, so a later bare {path} runs and makes the worktree" [ "$(git -C "$temporary_folder/$temporary_slug-after-quoted-opener" rev-parse --show-toplevel 2>/dev/null)" = "$temporary_folder/$temporary_slug-after-quoted-opener" ]
write_temporary_config "worktree_create: echo \"\`date\`\" > /dev/null; sh $work/temporary-worktrees/fake-create.sh {path} {base}\n"
"$P/scripts/steward.sh" tmp add "$phases_item" beside-backticks > "$work/temporary-worktrees.out" 2>&1
check "CreateCommandWithBarePathBesideClosedBackticks_MakesWorktree: backticks that close before a bare {path} leave the path outside them, so the command runs and makes the worktree" [ "$(git -C "$temporary_folder/$temporary_slug-beside-backticks" rev-parse --show-toplevel 2>/dev/null)" = "$temporary_folder/$temporary_slug-beside-backticks" ]
write_temporary_config "worktree_create: printf %s '\`' > /dev/null; sh $work/temporary-worktrees/fake-create.sh {path} {base}\n"
"$P/scripts/steward.sh" tmp add "$phases_item" after-quoted-backtick > "$work/temporary-worktrees.out" 2>&1
check "CreateCommandWithBarePathAfterSingleQuotedBacktick_MakesWorktree: a backtick inside single quotes opens nothing, so a later bare {path} runs and makes the worktree" [ "$(git -C "$temporary_folder/$temporary_slug-after-quoted-backtick" rev-parse --show-toplevel 2>/dev/null)" = "$temporary_folder/$temporary_slug-after-quoted-backtick" ]
injecting_phase='p$(>injected)'
write_temporary_config "$fake_temporary_create"
"$P/scripts/steward.sh" tmp add "$phases_item" "$injecting_phase" > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpAddOfPhaseWithShellCharacters_ExitsTwo: a phase holding a character outside letters, digits, . _ and - is refused, exit 2" [ "$code" = 2 ]
check "TmpAddOfPhaseWithShellCharacters_MakesNoFolder: the phase's folder never appears" [ ! -e "$temporary_folder/$temporary_slug-$injecting_phase" ]
"$P/scripts/steward.sh" tmp add "$phases_item" nested/inner > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpAddOfPhaseWithSlash_ExitsTwo: a phase holding / is refused, exit 2" [ "$code" = 2 ]
check "TmpAddOfPhaseWithSlash_MakesNoFolder: the phase's folder never appears" [ ! -e "$temporary_folder/$temporary_slug-nested" ]
cat > "$work/temporary-worktrees/main-create.sh" <<SCRIPT
#!/bin/sh
git -C "$PWD" worktree add -q --detach "\$1" main
SCRIPT
write_temporary_config "worktree_create: sh $work/temporary-worktrees/main-create.sh {path} {base}\n"
base_ignored_phase_worktree="$("$P/scripts/steward.sh" tmp add "$phases_item" phase-8 2>/dev/null)"
check "CreateCommandIgnoringBase_PhaseBranchStartsAtTaskTip: the phase's branch starts at the task branch's tip whatever the command checked out" [ "$(git -C "$base_ignored_phase_worktree" rev-parse HEAD)" = "$(git rev-parse "flow/$temporary_slug")" ]
git branch -q "flow/$temporary_slug-phase-9" main
write_temporary_config "$fake_temporary_create"
"$P/scripts/steward.sh" tmp add "$phases_item" phase-9 > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpAddOfPhaseWhoseBranchExists_ExitsTwo: a phase whose branch already exists is refused, exit 2" [ "$code" = 2 ]
check "TmpAddOfPhaseWhoseBranchExists_MakesNoFolder: the phase's folder never appears" [ ! -e "$temporary_folder/$temporary_slug-phase-9" ]
check "TmpAddOfPhaseWhoseBranchExists_KeepsThatBranch: the existing branch stays where it was" [ "$(git rev-parse "flow/$temporary_slug-phase-9")" = "$(git rev-parse main)" ]
cat > "$work/temporary-worktrees/branching-create.sh" <<SCRIPT
#!/bin/sh
git -C "$PWD" worktree add -q -b "flow/\$(basename "\$1")" "\$1" "\$2"
SCRIPT
write_temporary_config "worktree_create: sh $work/temporary-worktrees/branching-create.sh {path} {base}\n"
"$P/scripts/steward.sh" tmp add "$phases_item" branched > "$work/temporary-worktrees.out" 2>"$work/temporary-worktrees.err"
check "TmpAddWhoseBranchCannotBeMade_NamesLeftoverWorktree: the message names the made worktree and how to remove it" grep -q "tmp remove .*branched" "$work/temporary-worktrees.err"
"$P/scripts/steward.sh" tmp add "$phases_item" 'a/../../../../escaped' > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpAddOfPhaseClimbingOutOfTmp_ExitsTwo: a phase holding .. is refused, exit 2" [ "$code" = 2 ]
check "TmpAddOfPhaseClimbingOutOfTmp_MakesNoFolderOutsideTmp: the command never makes the folder the .. would reach" [ ! -e "$work/temporary-worktrees/escaped" ]
"$P/scripts/steward.sh" tmp add "$phases_item" 'b c~' > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpAddOfPhaseWithInvalidBranchCharacter_ExitsTwo: a phase that makes no valid branch name is refused, exit 2" [ "$code" = 2 ]
check "TmpAddOfPhaseWithInvalidBranchCharacter_MakesNoFolder: the command never makes the phase's folder" [ ! -e "$temporary_folder/$temporary_slug-b c~" ]
mkdir -p "$temporary_folder/$temporary_slug-phase-10"
"$P/scripts/steward.sh" tmp add "$phases_item" phase-10 > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpAddOntoExistingFolder_ExitsTwo: a phase whose folder already exists is refused, exit 2" [ "$code" = 2 ]
check "TmpAddOntoExistingFolder_MakesNoWorktreeThere: the existing folder does not become a worktree" [ ! -e "$temporary_folder/$temporary_slug-phase-10/.git" ]
write_temporary_config ''
"$P/scripts/steward.sh" tmp add "$phases_item" 'a/../../../../escaped' > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpAddOfPhaseClimbingOutOfTmpWithoutCreateCommand_ExitsTwo: a phase holding .. is refused, exit 2, when git makes the worktree" [ "$code" = 2 ]
check "TmpAddOfPhaseClimbingOutOfTmpWithoutCreateCommand_MakesNoFolderOutsideTmp: git never makes the folder the .. would reach" [ ! -e "$work/temporary-worktrees/escaped" ]
write_temporary_config "${fake_temporary_create}worktree_remove: sh $work/temporary-worktrees/folder-remove.sh {path}\n"
git worktree add -q --detach ../app-sibling
"$P/scripts/steward.sh" tmp remove ../app-sibling > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpRemoveOfWorktreeOutsideTmp_ExitsTwo: a listed worktree outside .flow/tmp is refused, exit 2" [ "$code" = 2 ]
check "TmpRemoveOfWorktreeOutsideTmp_KeepsFolder: the remove command never runs on a worktree outside .flow/tmp" [ -d ../app-sibling ]
git worktree add -q --detach ../app-gone && rm -rf ../app-gone
other_records_phase_worktree="$("$P/scripts/steward.sh" tmp add "$phases_item" phase-11 2>/dev/null)"
"$P/scripts/steward.sh" tmp remove "$other_records_phase_worktree" > "$work/temporary-worktrees.out" 2>&1
check_all "TmpRemoveWithRemoveCommand_KeepsOtherGitRecords: another worktree's record stays though its folder is gone" 'git worktree list --porcelain | grep -q "app-gone"'
other_branch_phase_worktree="$("$P/scripts/steward.sh" tmp add "$phases_item" phase-12 2>/dev/null)"
git -C "$other_branch_phase_worktree" switch -q -c owner-branch
"$P/scripts/steward.sh" tmp remove "$other_branch_phase_worktree" > "$work/temporary-worktrees.out" 2>&1
check "TmpRemoveOfWorktreeOnOtherBranch_KeepsThatBranch: a branch other than the phase's is never deleted" git rev-parse --verify -q refs/heads/owner-branch
check "TmpRemoveOfWorktreeOnOtherBranch_RemovesWorktree: a temporary worktree on another branch is still removed" [ ! -e "$other_branch_phase_worktree" ]
gitless_phase_worktree="$("$P/scripts/steward.sh" tmp add "$phases_item" phase-13 2>/dev/null)"
printf '.flow/\n' >> "$(git rev-parse --git-common-dir)/info/exclude"
printf 'precious\n' > "$gitless_phase_worktree/precious.txt"
rm -f "$gitless_phase_worktree/.git"
"$P/scripts/steward.sh" tmp remove "$gitless_phase_worktree" > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpRemoveOfWorktreeWithoutGitFile_ExitsTwo: a temporary worktree whose .git is gone is refused, exit 2" [ "$code" = 2 ]
check "TmpRemoveOfWorktreeWithoutGitFile_KeepsItsFiles: the remove command never runs, so its files stay" [ -f "$gitless_phase_worktree/precious.txt" ]
locked_phase_worktree="$("$P/scripts/steward.sh" tmp add "$phases_item" phase-14 2>/dev/null)"
git worktree lock "$locked_phase_worktree"
"$P/scripts/steward.sh" tmp remove "$locked_phase_worktree" > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpRemoveOfLockedWorktree_ExitsTwo: a locked temporary worktree is refused, exit 2" [ "$code" = 2 ]
check "TmpRemoveOfLockedWorktree_KeepsFolder: the remove command never runs on a locked worktree" [ -f "$locked_phase_worktree/README.md" ]
git worktree add -q --detach "$temporary_folder/pool-x"
write_temporary_config "  - .flow/tmp/pool-x\n${fake_temporary_create}worktree_remove: sh $work/temporary-worktrees/folder-remove.sh {path}\n"
"$P/scripts/steward.sh" tmp remove "$temporary_folder/pool-x" > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpRemoveOfPoolWorktreeUnderTmp_ExitsTwo: a pool worktree under .flow/tmp is refused, exit 2" [ "$code" = 2 ]
check "TmpRemoveOfPoolWorktreeUnderTmp_KeepsPoolWorktree: the remove command never runs on a pool worktree" [ -f "$temporary_folder/pool-x/README.md" ]
write_temporary_config "${fake_temporary_create}worktree_remove: sh $work/temporary-worktrees/folder-remove.sh {path}\n"
mv .flow/tmp .flow/tmp-moved && ln -s "$(cd .. && pwd -P)" .flow/tmp
"$P/scripts/steward.sh" tmp remove ../app-wt-1 > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpRemoveOfPoolWorktreeUnderSymlinkedTmp_ExitsTwo: a pool worktree is refused though a symlinked .flow/tmp puts it under the temporary folder" [ "$code" = 2 ]
check "TmpRemoveOfPoolWorktreeUnderSymlinkedTmp_KeepsPoolWorktree: the remove command never runs on the pool worktree" [ -f ../app-wt-1/README.md ]
"$P/scripts/steward.sh" tmp remove "$(pwd -P)" > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpRemoveOfMainWorktreeUnderSymlinkedTmp_ExitsTwo: the main worktree is refused though a symlinked .flow/tmp puts it under the temporary folder" [ "$code" = 2 ]
check "TmpRemoveOfMainWorktreeUnderSymlinkedTmp_KeepsMainWorktree: the remove command never runs on the main worktree" [ -f README.md ]
rm .flow/tmp && mv .flow/tmp-moved .flow/tmp
symlinked_phase_worktree="$("$P/scripts/steward.sh" tmp add "$phases_item" symlinked 2>/dev/null)"
mv .flow/tmp .flow/tmp-real && ln -s tmp-real .flow/tmp
"$P/scripts/steward.sh" tmp remove "$symlinked_phase_worktree" > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpRemoveUnderSymlinkedTmp_ExitsTwo: a temporary worktree is refused while .flow/tmp is a symlink, exit 2" [ "$code" = 2 ]
check "TmpRemoveUnderSymlinkedTmp_KeepsWorktree: the remove command never runs while .flow/tmp is a symlink" [ -f "$symlinked_phase_worktree/README.md" ]
rm .flow/tmp && mv .flow/tmp-real .flow/tmp
submodule_source="$work/temporary-worktrees/submodule-source"
git init -q -b main "$submodule_source" && git -C "$submodule_source" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
submodule_phase_worktree="$("$P/scripts/steward.sh" tmp add "$phases_item" submodule 2>/dev/null)"
git -C "$submodule_phase_worktree" -c protocol.file.allow=always submodule add -q "$submodule_source" sub
git config -f "$submodule_phase_worktree/.gitmodules" submodule.sub.ignore all
git -C "$submodule_phase_worktree" add .gitmodules && git -C "$submodule_phase_worktree" commit -qm "submodule whose changes git status hides"
printf 'change\n' > "$submodule_phase_worktree/sub/change.txt"
"$P/scripts/steward.sh" tmp remove "$submodule_phase_worktree" > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpRemoveOfWorktreeWithIgnoredSubmoduleChange_ExitsThree: a change in a submodule that .gitmodules tells git status to ignore is uncommitted, exit 3" [ "$code" = 3 ]
check "TmpRemoveOfWorktreeWithIgnoredSubmoduleChange_KeepsChange: the remove command never runs, so the submodule's change stays" [ -f "$submodule_phase_worktree/sub/change.txt" ]
untracked_submodule_phase_worktree="$("$P/scripts/steward.sh" tmp add "$phases_item" untracked-submodule 2>/dev/null)"
git -C "$untracked_submodule_phase_worktree" -c protocol.file.allow=always submodule add -q "$submodule_source" sub
git -C "$untracked_submodule_phase_worktree" commit -qm "submodule"
printf 'wip\n' > "$untracked_submodule_phase_worktree/sub/wip.txt"
git config --global status.showUntrackedFiles no
"$P/scripts/steward.sh" tmp remove "$untracked_submodule_phase_worktree" > "$work/temporary-worktrees.out" 2>&1; code=$?
git config --global --unset status.showUntrackedFiles
check "TmpRemoveOfSubmoduleUntrackedFileHiddenByGlobalStatusConfig_ExitsThree: an untracked file in a submodule counts as uncommitted though a global status.showUntrackedFiles=no hides it from the submodule's git status, exit 3" [ "$code" = 3 ]
check "TmpRemoveOfSubmoduleUntrackedFileHiddenByGlobalStatusConfig_KeepsFile: the remove command never runs, so the submodule's untracked file stays" [ -f "$untracked_submodule_phase_worktree/sub/wip.txt" ]
corrupt_index_phase_worktree="$("$P/scripts/steward.sh" tmp add "$phases_item" corrupt-index 2>/dev/null)"
printf 'change\n' >> "$corrupt_index_phase_worktree/README.md"
printf 'corrupt\n' > "$(git -C "$corrupt_index_phase_worktree" rev-parse --absolute-git-dir)/index"
"$P/scripts/steward.sh" tmp remove "$corrupt_index_phase_worktree" > "$work/temporary-worktrees.out" 2>&1; code=$?
check "TmpRemoveOfWorktreeWhoseStatusFails_ExitsThree: a temporary worktree whose git status fails is refused as possibly dirty, exit 3" [ "$code" = 3 ]
check "TmpRemoveOfWorktreeWhoseStatusFails_KeepsChange: the remove command never runs, so the uncommitted change stays" grep -q change "$corrupt_index_phase_worktree/README.md"

[ "$fails" -eq 0 ] && { echo "worktree-pool: ok"; exit 0; }
echo "worktree-pool: $fails failed"; exit 1
