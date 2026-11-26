#!/bin/sh
# profile-pin.sh: the size and the profile of a start and a re-size, on the local adapter in
# throwaway repos and on the GitHub fake. A start writes no size estimate and pins the profile; a
# size edited on the tracker after it is the next start's size; a re-size writes the estimate and
# one comment, never the tracker's size; next.sh --profile pins a profile and refuses, before any
# write, an unknown name, a profile without the item's step and a call with no item, and accepts a
# profile that holds a started item's step; the flow's own re-size re-selects over a pin, and says
# a profile change only when there is one; a flow: label selects no profile.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_state_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT

profile_refused_status=2
single_comment=1
# next_json <item> [option]...: next.sh's JSON for a start of the item.
next_json() { "$plugin/scripts/next.sh" "$@" --json 2>/dev/null; }
# refused_start <next.sh argument>...: next.sh's exit status, its output dropped.
refused_start() { "$plugin/scripts/next.sh" "$@" >/dev/null 2>&1; }
# fingerprint <file>...: one checksum line per file, to tell a file a refused start left alone.
fingerprint() { cksum "$@"; }
# resize_comments <item>: how many re-size comments the local item holds.
resize_comments() { grep -c 'Re-sized ' "$(item_file "$1")"; }

echo "start: no size estimate, the profile pinned"
new_repo starts
sized="$(new_task "Sized on the tracker")"
start_step "$sized"
check "Start_WritesNoSizeEstimate: because the size stays the tracker's until the flow re-sizes the item" \
  '[ -z "$(record get "$sized" size)" ]'
check "Start_PinsTheProfileTheSizeSelects: because the first start records the profile its later starts keep" \
  '[ "$(record get "$sized" profile)" = task-S ]'
end_run "$sized"
"$local_adapter/write-state.sh" "$sized" size=M
restarted="$(next_json "$sized")"
check "TrackerSizeEditedAfterTheFirstStart_IsTheNextStartsSize: because the record holds no estimate, so the tracker's size is read" \
  '[ "$(printf "%s" "$restarted" | json_value size)" = M ]'
check "TrackerSizeEditedAfterTheFirstStart_KeepsThePinnedProfile: because only a re-size or --profile selects a profile again" \
  '[ "$(printf "%s" "$restarted" | json_value profile)" = task-S ]'

echo "re-size: the estimate and one comment"
new_repo resizes
grown="$(new_task "Bigger than it looked")"
start_step "$grown"
step_result "$grown" implement '{"status":"done","summary":"It reaches two modules.","size":"M"}'
finish_step "$grown"
check "Resize_WritesTheSizeEstimate: because the flow's own estimate is the size every later step reads" \
  '[ "$(record get "$grown" size)" = M ]'
check "Resize_LeavesTheTrackersSize: because under tracker_state none no size reaches the tracker" \
  '[ "$("$local_adapter/read.sh" "$grown" | json_value size)" = S ]'
check "Resize_PostsOneComment: because the owner reads the re-size once on the item" \
  '[ "$(resize_comments "$grown")" -eq "$single_comment" ]'
check "Resize_SaysTheOldAndTheNewSize: because the comment tells the owner what changed and where" \
  'grep -q "Re-sized S -> M at step implement" "$(item_file "$grown")"'
check "ResizeThatSelectsAnotherProfile_SaysTheProfileChange: because the owner learns the steps ahead changed" \
  'grep -q "Profile task-S -> task-M" "$(item_file "$grown")"'

echo "--profile: a pin at the start"
new_repo pins
pinned="$(new_task "Pinned deeper")"
pinned_start="$(next_json "$pinned" --profile task-M)"
check "ProfileOption_PinsTheProfile: because the record holds the named profile over the one the size selects" \
  '[ "$(record get "$pinned" profile)" = task-M ]'
check "ProfileOption_StartsAtTheProfilesFirstStep: because an unstarted item begins where the pinned profile begins" \
  '[ "$(printf "%s" "$pinned_start" | json_value step)" = design ]'

echo "--profile: a pin on a started item, and a re-size after a pin"
started_at_implement="$(new_task "Started small, pinned deeper")"
start_step "$started_at_implement"; end_run "$started_at_implement"
next_json "$started_at_implement" --profile task-L >/dev/null
check "ProfileHoldingTheStartedItemsStep_PinsIt: because task-L has implement, so the item at implement goes on under it" \
  '[ "$(record get "$started_at_implement" profile)" = task-L ]'

regrown="$(new_task "Pinned, then found bigger")"
next_json "$regrown" --profile task-M >/dev/null
step_result "$regrown" design '{"status":"done","summary":"It reaches three modules.","size":"L"}'
finish_step "$regrown"
check "ResizeAfterAProfilePin_SelectsTheProfileOfTheNewSize: because the flow's own re-size re-selects over a pin" \
  '[ "$(record get "$regrown" profile)" = task-L ]'

echo "re-size within one profile"
same_profile="$("$plugin/scripts/new.sh" task "Large, then larger" --size L --body "Large from the start.")"
start_step "$same_profile"
step_result "$same_profile" design '{"status":"done","summary":"It reaches five modules.","size":"XL"}'
finish_step "$same_profile"
check "ResizeThatKeepsTheProfile_StillPostsTheComment: because every re-size that raises no gate is said on the item" \
  'grep -q "Re-sized L -> XL at step design" "$(item_file "$same_profile")"'
check "ResizeThatKeepsTheProfile_SaysNoProfileChange: because L and XL both select task-L, so no profile line is posted" \
  '! grep -q "Profile task-" "$(item_file "$same_profile")"'

echo "--profile: refusals write nothing"
unknown="$(new_task "Unknown profile")"
unknown_before="$(fingerprint "$(item_file "$unknown")")"
refused_start "$unknown" --profile task-XL; unknown_status=$?
check "UnknownProfile_ExitsTwo: because a name that is no profile in profiles.json is refused" \
  '[ "$unknown_status" -eq "$profile_refused_status" ]'
check "UnknownProfile_RecordsNothing: because a refused start leaves the item without a record" \
  '[ ! -e "$(record path "$unknown")" ]'
check "UnknownProfile_LeavesTheTrackerAsItWas: because a refused start writes nothing to the item" \
  '[ -n "$unknown_before" ] && [ "$(fingerprint "$(item_file "$unknown")")" = "$unknown_before" ]'

started="$(new_task "Started at implement")"
start_step "$started"; end_run "$started"
started_before="$(fingerprint "$(record path "$started")" "$(item_file "$started")")"
refused_start "$started" --profile epic; stepless_status=$?
check "ProfileWithoutTheItemsStep_ExitsTwo: because an item at implement cannot go on under a profile with no implement" \
  '[ "$stepless_status" -eq "$profile_refused_status" ]'
check "ProfileWithoutTheItemsStep_WritesNothing: because a refused start changes neither the record nor the item" \
  '[ -n "$started_before" ] && [ "$(fingerprint "$(record path "$started")" "$(item_file "$started")")" = "$started_before" ]'

new_repo unnamed
ready="$(new_task "The one ready item")"
refused_start --profile task-S; unnamed_status=$?
check "ProfileWithNoItem_ExitsTwo: because a pick has no item to pin a profile on" \
  '[ "$unnamed_status" -eq "$profile_refused_status" ]'
check "ProfileWithNoItem_StartsNothing: because the one ready item, the one a pick would take, holds no record" \
  '[ ! -e "$(record path "$ready")" ]'

echo "a flow: label on the GitHub fake"
new_repo labelled
P="$plugin"; . "$here/_github_fixture.sh"
python3 -c 'import json, sys
path = sys.argv[1]; issues = json.load(open(path))
next(issue for issue in issues["issues"] if issue["number"] == 11)["labels"].append("flow:task-L")
json.dump(issues, open(path, "w"))' "$FAKE_GH_DIR/issues.json"
labelled_start="$(next_json 'gh#11')"
check "FlowLabelOnASmallTask_SelectsNoProfile: because the size S selects task-S, since the flow: label is no longer read" \
  '[ "$(printf "%s" "$labelled_start" | json_value profile)" = task-S ]'

[ "$fails" -eq 0 ] && { echo "profile-pin: ok"; exit 0; }
echo "profile-pin: $fails failed"; exit 1
