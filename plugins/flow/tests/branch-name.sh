#!/bin/sh
# branch-name.sh: the task branch a claim names from the branch template of .flow/config.yaml, on
# the local adapter (and one Jira item on the fake Jira) in throwaway repos with a bare origin. The
# name the key and title rules give, the name a claim records, the name a re-claim and a claim made
# before the template keep, the names a claim refuses before it creates anything, and the phase
# branch of a temporary worktree.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

branch_lib() { sh -c '. "$FLOW_PLUGIN/lib/flow.sh" && . "$FLOW_PLUGIN/lib/base.sh" && . "$FLOW_PLUGIN/lib/branch.sh" && "$@"' _ "$@"; }
claim_branch_of() { json_value branch < "$("$plugin/scripts/steward.sh" find "$1")/.flow/claim.json"; }
number_of() { printf '%s' "${1##*/}"; }
worktree_count() { git worktree list | wc -l | tr -d ' '; }
set_branch_config() { printf '%s\n' "$1" >> .flow/config.yaml; }
retitle() { sed -i.before "s/^title:.*/title: $2/" ".flow/items/$(printf '%s' "${1#local:}" | sed 's|/.*||')/$(number_of "$1").md"; }
per_kind_templates='branch:
  task: task/{key}-{title}
  bug: bugfix/{key}-{title}
  epic: feature/{key}-{title}'

echo "branch: the key and title rules"
for key_row in 'gh#73 73' 'jira:PROJ-123 proj-123' 'local:task/3 task-3'; do
  tracker_id="${key_row% *}"; expected_key="${key_row#* }"
  check "BranchKey_TrackerId_IsTheIdPastItsPrefixLowerCased [$tracker_id]: {key} is the tracker's own id, so a Jira project reads it in the branch" \
    '[ "$(branch_lib branch_key "$tracker_id")" = "$expected_key" ]'
done
check "BranchTitle_AccentedTitle_FoldsToAscii: a branch name stays ASCII, so every CI and cache path takes it" \
  '[ "$(branch_lib branch_title "Réglage chronomètre")" = reglage-chronometre ]'
check "BranchTitle_TitleOverTheCap_KeepsFortyCharacters: a long title is cut, so the branch name stays short" \
  '[ "$(branch_lib branch_title "Drill timer for the penalty shootout practice rounds")" = drill-timer-for-the-penalty-shootout-pra ]'
check "BranchTitle_CutLandingOnADash_LeavesNoTrailingDash: the cut never leaves a name ending in -" \
  '[ "$(branch_lib branch_title "Drill timer for the penalty shootout in rounds")" = drill-timer-for-the-penalty-shootout-in ]'
check "BranchRender_TitleWithNoLetters_LeavesNoTrailingDash: an empty title slug gives task/<key>, not task/<key>-" \
  '[ "$(branch_lib branch_render "task/{key}-{title}" local:task/3 task "!!!")" = task/task-3 ]'

echo "branch: the claim names and records the task branch"
new_repo default
plain="$(new_task "Drill timer")"
"$plugin/scripts/next.sh" "$plain" >/dev/null 2>&1
check "UnsetTemplate_ClaimJsonRecordsFlowSlug: with no branch config a claim keeps today's flow/<slug>" \
  '[ "$(claim_branch_of "$plain")" = "flow/$(slug "$plain")" ]'
check "UnsetTemplate_StateRecordsFlowSlug: the item state holds the same name, so a reader with no claim finds it" \
  '[ "$(state "$plain" branch)" = "flow/$(slug "$plain")" ]'

new_repo kinds
set_branch_config "$per_kind_templates"
kind_task="$(new_task "Drill timer")"
kind_bug="$("$plugin/scripts/new.sh" bug "Stuck ball" --size S --body "$body")"
kind_epic="$("$local_adapter/create.sh" epic "Leagues" --size L --body x)"
for claimed in "$kind_task" "$kind_bug" "$kind_epic"; do "$plugin/scripts/steward.sh" claim "$claimed" >/dev/null 2>&1; done
check "PerKindTemplateForATask_ClaimsTheTaskTemplate: a task takes branch.task" \
  '[ "$(claim_branch_of "$kind_task")" = "task/task-$(number_of "$kind_task")-drill-timer" ]'
check "PerKindTemplateForABug_ClaimsTheBugTemplate: a bug takes branch.bug, so a CI that wants bugfix/ accepts it" \
  '[ "$(claim_branch_of "$kind_bug")" = "bugfix/bug-$(number_of "$kind_bug")-stuck-ball" ]'
check "PerKindTemplateForAnEpic_ClaimsTheEpicTemplate: an epic takes branch.epic" \
  '[ "$(claim_branch_of "$kind_epic")" = "feature/epic-$(number_of "$kind_epic")-leagues" ]'
check "PerKindTemplate_StateRecordsTheRenderedName: the item state holds the name the claim took" \
  '[ "$(state "$kind_bug" branch)" = "bugfix/bug-$(number_of "$kind_bug")-stuck-ball" ]'
check "PerKindTemplate_TheBranchExistsInTheWorktree: the claimed worktree is on the recorded branch" \
  '[ "$(git -C "$("$plugin/scripts/steward.sh" find "$kind_task")" branch --show-current)" = "task/task-$(number_of "$kind_task")-drill-timer" ]'

new_repo scalar
set_branch_config 'branch: work/{kind}/{key}'
scalar_bug="$("$plugin/scripts/new.sh" bug "Stuck ball" --size S --body "$body")"
"$plugin/scripts/steward.sh" claim "$scalar_bug" >/dev/null 2>&1
check "ScalarTemplate_AppliesToABug: one template names every kind's branch" \
  '[ "$(claim_branch_of "$scalar_bug")" = "work/bug/bug-$(number_of "$scalar_bug")" ]'

echo "branch: a Jira item's key names its branch"
new_repo jira
mkdir -p "$work/jira" "$work/jirabin" && cp "$here/_fake_jira.py" "$work/jira/" && ln -s "$here/fake-jira.sh" "$work/jirabin/curl"
python3 -c 'import json,sys
issue = {"key": "PROJ-123", "properties": {}, "comments": [], "remotelinks": [], "fields": {"summary": "Drill timer", "labels": [], "priority": None,
  "status": {"name": "To Do", "statusCategory": {"key": "new"}}, "issuetype": {"name": "Task"}, "description": None}}
json.dump({"issues": {"PROJ-123": issue}, "transitions": []}, open(sys.argv[1], "w"))' "$work/jira/jira.json"
printf 'adapters:\n  default: jira\nbase: main\npool:\n  - ../wt-1\n  - ../wt-2\n  - ../wt-3\npool_max: 8\nnotify:\n  desktop: false\njira:\n  site: https://acme.atlassian.net\n  project: PROJ\n  email: flow@acme.test\n%s\n' "$per_kind_templates" > .flow/config.yaml
env PATH="$work/jirabin:$PATH" FAKE_JIRA_DIR="$work/jira" FLOW_JIRA_RETRY_WAIT="0 0" JIRA_API_TOKEN=run-token \
  "$plugin/scripts/steward.sh" claim jira:PROJ-123 >/dev/null 2>&1
check "JiraItemUnderAKeyTemplate_ClaimsTheLowerCasedIssueKey: the Jira key is in the branch name, so Jira links the branch to the issue" \
  '[ "$(claim_branch_of jira:PROJ-123)" = task/proj-123-drill-timer ]'

echo "branch: a claim keeps the name it recorded"
new_repo kept
set_branch_config "$per_kind_templates"
renamed="$(new_task "Drill timer")"
renamed_branch="task/task-$(number_of "$renamed")-drill-timer"
renamed_worktree="$("$plugin/scripts/steward.sh" claim "$renamed" 2>/dev/null)"
printf 'work\n' > "$renamed_worktree/work.txt" && git -C "$renamed_worktree" add work.txt && git -C "$renamed_worktree" commit -qm work
"$plugin/scripts/steward.sh" release "$renamed" >/dev/null 2>&1
retitle "$renamed" "Penalty clock"
check "RetitledItem_ReadsTheNewTitle: the tracker gives the new title, or the re-claim check below proves nothing" \
  '[ "$("$local_adapter/read.sh" "$renamed" | json_value title)" = "Penalty clock" ]'
"$plugin/scripts/steward.sh" claim "$renamed" >/dev/null 2>&1
check "TitleRenamedAfterTheClaim_ReclaimTakesTheRecordedBranch: a title edit never renames the branch, so the work on it is picked up again" \
  '[ "$(claim_branch_of "$renamed")" = "$renamed_branch" ]'
check "TitleRenamedAfterTheClaim_ReclaimHoldsTheEarlierWork: the re-claim is on the branch that holds the first claim's commit" \
  '[ -f "$("$plugin/scripts/steward.sh" find "$renamed")/work.txt" ]'
hooked="$(new_task "Drill timer")"
hooked_branch="task/task-$(number_of "$hooked")-drill-timer"
"$plugin/scripts/steward.sh" claim "$hooked" >/dev/null 2>&1
"$plugin/scripts/steward.sh" release "$hooked" >/dev/null 2>&1
retitle "$hooked" "Penalty clock"
hooked_worktree="$(printf '{"name":"%s","cwd":"%s"}' "$(slug "$hooked")" "$PWD" | "$plugin/hooks/worktree-create.sh" 2> "$work/hooked.err" | tail -n 1)"
check "WorktreeSessionOnARetitledItem_ClaimsTheRecordedBranch: the hook reads the item with its record, so a title edit never renames the branch a session opens on" \
  '[ "$(git -C "$hooked_worktree" branch --show-current)" = "$hooked_branch" ]'
check "WorktreeSessionOnARetitledItem_StderrHasNoAdapterAloneGuardLine: the hook asks the record of an item read with it, so the guard never fires" \
  '! grep -qF "asked of an item read from its adapter alone" "$work/hooked.err"'

legacy="$(new_task "Drill timer")"
git branch "flow/$(slug "$legacy")" main
"$plugin/scripts/steward.sh" claim "$legacy" >/dev/null 2>&1
check "ClaimMadeBeforeTheTemplate_KeepsFlowSlug: an item whose flow/<slug> branch exists keeps it under a template, so its work is not left behind" \
  '[ "$(claim_branch_of "$legacy")" = "flow/$(slug "$legacy")" ]'

echo "branch: a claim trusts a recorded name only when the flow could have given it"
new_repo recorded
set_branch_config "$per_kind_templates"
remote_branch develop && git fetch -q origin && git remote set-head origin develop
for recorded_row in 'ForeignBranch release/2.0' 'ConfigBase main' 'OriginDefaultBranch develop'; do
  recorded_label="${recorded_row% *}"; recorded_name="${recorded_row#* }"
  forged="$(new_task "Drill timer")"
  "$plugin/scripts/state.sh" set "$forged" "branch=$recorded_name" >/dev/null 2>&1
  "$plugin/scripts/steward.sh" claim "$forged" >/dev/null 2>&1
  check "RecordedBranchIs${recorded_label}_ClaimRendersTheTemplate [$recorded_name]: the item state is tracker text anyone may write, so a claim never commits to a branch the template could not name" \
    '[ "$(claim_branch_of "$forged")" = "task/task-$(number_of "$forged")-drill-timer" ]'
done
recorded_legacy="$(new_task "Drill timer")"
"$plugin/scripts/state.sh" set "$recorded_legacy" "branch=flow/$(slug "$recorded_legacy")" >/dev/null 2>&1
"$plugin/scripts/steward.sh" claim "$recorded_legacy" >/dev/null 2>&1
check "RecordedFlowSlugWithNoLocalBranch_ClaimKeepsFlowSlug: a claim made before the template, released and pruned, keeps its pushed name" \
  '[ "$(claim_branch_of "$recorded_legacy")" = "flow/$(slug "$recorded_legacy")" ]'

echo "branch: a claim refuses a name before it creates anything"
new_repo refused
set_branch_config 'branch: task/{key}..x'
invalid="$(new_task "Drill timer")"
worktrees_before="$(worktree_count)"; branches_before="$(git branch --list | wc -l | tr -d ' ')"
"$plugin/scripts/next.sh" "$invalid" >/dev/null 2>&1; invalid_code=$?
check "TemplateRenderingAnInvalidName_NamedRunExitsWithTheConfigCode: a name git refuses is a config error, exit 2" \
  '[ "$invalid_code" -eq 2 ]'
check "TemplateRenderingAnInvalidName_ClaimsNoWorktree: the item is not claimed" \
  '[ -z "$("$plugin/scripts/steward.sh" find "$invalid")" ]'
check "TemplateRenderingAnInvalidName_GrowsNoWorktree: the pool is not grown for a claim that cannot happen" \
  '[ "$(worktree_count)" = "$worktrees_before" ]'
check "TemplateRenderingAnInvalidName_CreatesNoBranch: no branch is left behind" \
  '[ "$(git branch --list | wc -l | tr -d " ")" = "$branches_before" ]'
"$plugin/scripts/steward.sh" claim "$invalid" >/dev/null 2>&1; direct_invalid_code=$?
check "StewardClaimOfAnInvalidName_ExitsWithTheConfigCode: steward's own claim refuses the name too" \
  '[ "$direct_invalid_code" -eq 2 ]'

new_repo base_named
set_branch_config 'branch: task/{key}'
onto_base="$(new_task "Drill timer")"
template_base="task/task-$(number_of "$onto_base")"
git branch "$template_base" main
worktrees_before="$(worktree_count)"; branches_before="$(git branch --list | wc -l | tr -d ' ')"
base_tip_before="$(git rev-parse "$template_base")"
"$plugin/scripts/steward.sh" claim "$onto_base" --base "$template_base" >/dev/null 2>&1; template_base_code=$?
check "TemplateRenderingTheClaimBase_ExitsWithTheConfigCode: a task branch that is its own base would put the work straight onto the base, exit 2" \
  '[ "$template_base_code" -eq 2 ]'
check "TemplateRenderingTheClaimBase_ClaimsNoWorktree: the item is not claimed" \
  '[ -z "$("$plugin/scripts/steward.sh" find "$onto_base")" ]'
check "TemplateRenderingTheClaimBase_GrowsNoWorktree: the pool is not grown for a refused claim" \
  '[ "$(worktree_count)" = "$worktrees_before" ]'
check "TemplateRenderingTheClaimBase_CreatesNoBranch: no branch is left behind" \
  '[ "$(git branch --list | wc -l | tr -d " ")" = "$branches_before" ]'
check "TemplateRenderingTheClaimBase_LeavesTheBaseUntouched: the base keeps its tip" \
  '[ "$(git rev-parse "$template_base")" = "$base_tip_before" ]'

main_tip_before="$(git rev-parse main)"
"$plugin/scripts/steward.sh" claim "$onto_base" --branch main >/dev/null 2>&1; option_base_code=$?
check "BranchOptionNamingTheConfigBase_ExitsWithTheConfigCode: --branch main would put the work straight onto the base, exit 2" \
  '[ "$option_base_code" -eq 2 ]'
check "BranchOptionNamingTheConfigBase_ClaimsNoWorktree: the item is not claimed" \
  '[ -z "$("$plugin/scripts/steward.sh" find "$onto_base")" ]'
check "BranchOptionNamingTheConfigBase_GrowsNoWorktree: the pool is not grown for a refused claim" \
  '[ "$(worktree_count)" = "$worktrees_before" ]'
check "BranchOptionNamingTheConfigBase_CreatesNoBranch: no branch is left behind" \
  '[ "$(git branch --list | wc -l | tr -d " ")" = "$branches_before" ]'
check "BranchOptionNamingTheConfigBase_LeavesTheBaseUntouched: main keeps its tip" \
  '[ "$(git rev-parse main)" = "$main_tip_before" ]'

remote_branch develop && git fetch -q origin && git remote set-head origin develop
"$plugin/scripts/steward.sh" claim "$onto_base" --branch develop >/dev/null 2>&1; origin_default_code=$?
check "BranchOptionNamingOriginsDefault_ExitsWithTheConfigCode: --branch develop when origin's HEAD is develop would make origin's default a task branch, exit 2" \
  '[ "$origin_default_code" -eq 2 ]'
check "BranchOptionNamingOriginsDefault_ClaimsNoWorktree: the item is not claimed" \
  '[ -z "$("$plugin/scripts/steward.sh" find "$onto_base")" ]'
check "BranchOptionNamingOriginsDefault_CreatesNoBranch: no local develop branch is left behind" \
  '! git show-ref --verify --quiet refs/heads/develop'

new_repo taken
set_branch_config 'branch: task/shared'
holder="$(new_task "Drill timer")"
"$plugin/scripts/steward.sh" claim "$holder" >/dev/null 2>&1
second="$(new_task "Penalty clock")"
worktrees_before="$(worktree_count)"
"$plugin/scripts/next.sh" "$second" >/dev/null 2>&1; taken_code=$?
check "NameAnotherLiveClaimHolds_NamedRunExitsWithThePassOverCode: the item is passed over, exit 4" \
  '[ "$taken_code" -eq 4 ]'
check "NameAnotherLiveClaimHolds_ClaimsNoWorktree: the second item is not claimed onto the first one's branch" \
  '[ -z "$("$plugin/scripts/steward.sh" find "$second")" ]'
check "NameAnotherLiveClaimHolds_GrowsNoWorktree: the pool is not grown for a refused claim" \
  '[ "$(worktree_count)" = "$worktrees_before" ]'
check "NameAnotherLiveClaimHolds_HolderKeepsItsBranch: the live claim is untouched" \
  '[ "$(claim_branch_of "$holder")" = task/shared ]'

echo "branch: a phase branch is <branch>-<phase>"
new_repo phases
set_branch_config "$per_kind_templates"
phased="$(new_task "Drill timer")"
phased_worktree="$("$plugin/scripts/steward.sh" claim "$phased" 2>/dev/null)"
printf 'task work\n' > "$phased_worktree/task.txt" && git -C "$phased_worktree" add task.txt && git -C "$phased_worktree" commit -qm task
phase_worktree="$("$plugin/scripts/steward.sh" tmp add "$phased" render 2>/dev/null | tail -n 1)"
check "TmpAddUnderATemplate_PhaseBranchIsTheTaskBranchAndPhase: the phase branch follows the task branch's template, so CI accepts it" \
  '[ "$(git -C "$phase_worktree" branch --show-current)" = "task/task-$(number_of "$phased")-drill-timer-render" ]'
check "TmpAddUnderATemplate_PhaseStartsFromTheTaskBranch: the phase holds the task branch's work" \
  '[ -f "$phase_worktree/task.txt" ]'
"$plugin/scripts/steward.sh" tmp remove "$phase_worktree" >/dev/null 2>&1
check "TmpRemoveUnderATemplate_DeletesThePhaseBranch: the phase branch tmp add named from the task branch goes with its worktree" \
  '! git show-ref --verify -q "refs/heads/task/task-$(number_of "$phased")-drill-timer-render"'
printf '#!/bin/sh\ngit -C "%s" worktree add -q --detach "$1" "$2"\n' "$PWD" > "$work/phase-create.sh"
set_branch_config "worktree_create: sh $work/phase-create.sh {path} {base}"
created_phase_worktree="$("$plugin/scripts/steward.sh" tmp add "$phased" created 2>/dev/null | tail -n 1)"
check "TmpAddUnderATemplateWithCreateCommand_PhaseBranchIsTheTaskBranchAndPhase: the made worktree goes onto the phase branch the template's task branch names" \
  '[ "$(git -C "$created_phase_worktree" branch --show-current)" = "task/task-$(number_of "$phased")-drill-timer-created" ]'
check "TmpAddUnderATemplateWithCreateCommand_PhaseStartsFromTheTaskBranch: the command gets the task branch as {base}, so the phase holds its work" \
  '[ -f "$created_phase_worktree/task.txt" ]'

[ "$fails" -eq 0 ] && { echo "branch-name: ok"; exit 0; }
echo "branch-name: $fails failed"; exit 1
