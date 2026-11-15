#!/bin/sh
# base-claim.sh: where a new claim starts, on the local adapter in throwaway repos with a bare
# origin. From the parent's claimed branch, else the nearest ancestor's epic/<n> on the remote, else
# a base: line in the body, else the config base; a base: line naming a missing branch or a name
# that is not safe passes the item over, in any locale; a tampered claim.json base is never handed
# on; steward's own claim refuses an unsafe --base; the epic walk stops at an id no adapter owns.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"

echo "base: where a claim starts when there is no epic branch next to it"
new_repo walk
grandparent_epic="$("$local_adapter/create.sh" epic "Drills" --size L --body x)"
grandparent_epic_branch="$(epic_of "$grandparent_epic")"
remote_branch "$grandparent_epic_branch"; remote_commit "$grandparent_epic_branch" drills.txt
move_task_numbers_past_the_epic_numbers one two
middle="$(new_task "Drill set" "$grandparent_epic")"
grandchild="$(new_task "Drill timer" "$middle")"
"$plugin/scripts/next.sh" "$grandchild" >/dev/null 2>&1
check "GrandchildWhoseParentHasNoEpicBranch_TakesTheGrandparentsEpicBranch: the walk goes up past a parent with no epic/<n> to the nearest ancestor that has one" \
  '[ "$(claim_base "$grandchild")" = "$grandparent_epic_branch" ]'
parent="$(new_task "Tuning instrument")"
"$plugin/scripts/steward.sh" claim "$parent" >/dev/null 2>&1
competing_epic_branch="$(epic_of "$parent")"
remote_branch "$competing_epic_branch"
kid="$(new_task "Tuning panel" "$parent")"
"$plugin/scripts/next.sh" "$kid" >/dev/null 2>&1
check "ChildOfAClaimedParentThatAlsoHasAnEpicBranch_TakesTheParentsTaskBranch: a parent's claimed branch comes before any epic branch, so the child's PR lands on its parent's work" \
  '[ "$(claim_base "$kid")" = "flow/$(slug "$parent")" ]'
lined_kid="$(new_task "Tuning readout" "$parent" "base: plan/sandbox
$body")"
remote_branch plan/sandbox; remote_commit plan/sandbox plan.txt
"$plugin/scripts/next.sh" "$lined_kid" >/dev/null 2>&1
check "ChildOfAClaimedParentWithABaseLine_TakesTheParentsTaskBranch: a parent's claimed branch comes before a base: line, so the child's PR lands on its parent's work" \
  '[ "$(claim_base "$lined_kid")" = "flow/$(slug "$parent")" ]'
ruled="$(new_task "Drill scoring" "$grandparent_epic" "base: plan/sandbox
$body")"
"$plugin/scripts/next.sh" "$ruled" >/dev/null 2>&1
check "EpicChildWithABaseLine_TakesTheEpicBranch: an ancestor's epic branch comes before a base: line, so a child of an epic stays on the epic" \
  '[ "$(claim_base "$ruled")" = "$grandparent_epic_branch" ]'
lined="$(new_task "Sandbox plan" "" "base: plan/sandbox
$body")"
"$plugin/scripts/next.sh" "$lined" >/dev/null 2>&1; git fetch -q origin
check "NoParentWithABaseLine_ClaimJsonRecordsThatBranch: an item with no parent link takes the branch its base: line names" \
  '[ "$(claim_base "$lined")" = plan/sandbox ]'
check "NoParentWithABaseLine_BranchDescendsFromIt: the claim starts from the named branch, so its commit is on the task branch" \
  'git -C "$("$plugin/scripts/steward.sh" find "$lined")" merge-base --is-ancestor origin/plan/sandbox HEAD'
loose="$(new_task "Loose docs")"
"$plugin/scripts/next.sh" "$loose" >/dev/null 2>&1
check "NoParentNoBaseLine_TakesTheConfigBase: with nothing else to go on the claim starts from the config base" \
  '[ "$(claim_base "$loose")" = main ]'
bare="$("$local_adapter/create.sh" epic "No branch yet" --size L --body x)"
move_task_numbers_past_the_epic_numbers three four
orphan="$(new_task "Early slice" "$bare")"
"$plugin/scripts/next.sh" "$orphan" >/dev/null 2>&1
check "ChildOfAnEpicWithNoEpicBranch_TakesTheConfigBase: an epic whose epic/<n> is not on the remote gives no base, so the claim falls through" \
  '[ "$(claim_base "$orphan")" = main ]'

echo "base: a base: line naming a missing branch passes the item over"
missing="$(new_task "Gone plan" "" "base: plan/gone
$body")"
"$plugin/scripts/next.sh" "$missing" >/dev/null 2>&1; code=$?
check "BaseLineNamingAMissingBranch_NamedRunExitsWithThePassOverCode: a named run of an item whose base is not on the remote exits 4" \
  '[ "$code" -eq 4 ]'
check "BaseLineNamingAMissingBranch_ClaimsNoWorktree: the item is never claimed from the config base instead" \
  '[ -z "$("$plugin/scripts/steward.sh" find "$missing")" ]'
check "BaseLineNamingAMissingBranch_LastEventNamesTheBranch: the owner sees which base is missing" \
  'state "$missing" last_event | grep -qF plan/gone'
check "BaseNameRefused_IsReadFromLibBase: an empty reason matches any last_event, so the rows below would prove nothing" \
  '[ -n "$base_name_refused" ]'
for unsafe_name in "$name_with_a_shell_character" "$name_git_reads_as_an_option" \
  "$name_climbing_a_level" "$name_from_the_root" "$name_with_a_letter_outside_ascii"; do
  unsafe="$(new_task "Odd plan $unsafe_name" "" "base: $unsafe_name
$body")"
  "$plugin/scripts/next.sh" "$unsafe" >/dev/null 2>&1; unsafe_code=$?
  check "BaseLineOutsideTheSafeNames_ClaimsNoWorktree [$unsafe_name]: a base: name outside the safe set is refused, never claimed from the config base, so it cannot reach a brief or a git command" \
    '[ -z "$("$plugin/scripts/steward.sh" find "$unsafe")" ]'
  check "BaseLineOutsideTheSafeNames_NamedRunExitsWithThePassOverCode [$unsafe_name]: a refused base passes the item over like a missing one" \
    '[ "$unsafe_code" -eq 4 ]'
  check "BaseLineOutsideTheSafeNames_LastEventSaysTheNameIsNotValid [$unsafe_name]: the owner sees the base was refused as a name, not reported missing from the remote" \
    'state "$unsafe" last_event | grep -qF -- "$base_name_refused"'
  check "BaseLineOutsideTheSafeNames_LastEventLeavesTheNameOut [$unsafe_name]: a refused name may carry control characters, so it never reaches last_event" \
    '! state "$unsafe" last_event | grep -qF -- "$unsafe_name"'
done
spaced="$(new_task "Spaced plan" "" "base: $name_with_a_space
$body")"
"$plugin/scripts/next.sh" "$spaced" >/dev/null 2>&1; spaced_code=$?
check "BaseLineWithASpace_ClaimsNoWorktree: the body parser ends the name at the first blank, and plan/x is not on the remote, so nothing is claimed" \
  '[ -z "$("$plugin/scripts/steward.sh" find "$spaced")" ]'
check "BaseLineWithASpace_NamedRunExitsWithThePassOverCode: the cut name is missing, so the item is passed over" \
  '[ "$spaced_code" -eq 4 ]'
check "BaseLineWithASpace_LastEventNamesTheNameCutAtTheSpace: the owner sees the branch the claim looked for, the name up to the blank" \
  'state "$spaced" last_event | grep -qF -- "${name_with_a_space%% *}"'

echo "base: a recorded base that is not a safe name is never handed on"
loose_worktree="$("$plugin/scripts/steward.sh" find "$loose")"
printf 'loose\n' > "$loose_worktree/loose.txt" && git -C "$loose_worktree" add loose.txt && git -C "$loose_worktree" commit -qm loose
for tampered_label in $tampered_labels; do
  eval "tampered_name=\"\$$tampered_label\""
  set_claim_base "$loose" "$tampered_name"
  rm -f "$(run_file "$loose")"
  "$plugin/scripts/next.sh" "$loose" --json > "$work/tampered.json" 2>/dev/null
  check "TamperedClaimBase_JsonBaseIsTheConfigBase [$tampered_label]: next.sh checks the name claim.json records and falls back to the config base, so a bad name never reaches the runner or git" \
    '[ "$(json_value base < "$work/tampered.json")" = main ]'
  set_claim_base "$loose" "$tampered_name"
  rm -f "$("$plugin/scripts/steward.sh" reports "$loose")/verify.json"
  (cd "$loose_worktree" && "$plugin/scripts/verify.sh" "$loose" >/dev/null 2>&1)
  check "TamperedClaimBase_VerifyDiffsAgainstTheConfigBase [$tampered_label]: verify.sh checks the name claim.json records and measures the item's own files from the config base" \
    '[ "$(json_value changed_files < "$("$plugin/scripts/steward.sh" reports "$loose")/verify.json")" = "[\"loose.txt\"]" ]'
done

echo "base: steward's own claim refuses a base that is not a safe name"
direct="$(new_task "Direct claim")"
for tampered_label in $tampered_labels; do
  eval "tampered_name=\"\$$tampered_label\""
  "$plugin/scripts/steward.sh" claim "$direct" --base "$tampered_name" >/dev/null 2>&1; direct_code=$?
  check "StewardClaimWithAnUnsafeBase_ExitsWithTheUsageCode [$tampered_label]: a caller other than next.sh cannot record a base that fails the name check" \
    '[ "$direct_code" -eq 2 ]'
  check "StewardClaimWithAnUnsafeBase_ClaimsNoWorktree [$tampered_label]: the refused claim leaves the item with no pool worktree" \
    '[ -z "$("$plugin/scripts/steward.sh" find "$direct")" ]'
done
# A --base with no branch after it: the claim runs in the background and is killed after 20
# seconds with 124, so a claim that loops for ever fails the check instead of hanging the suite.
"$plugin/scripts/steward.sh" claim "$direct" --base >/dev/null 2>&1 & bare_claim_pid=$!
bare_claim_seconds=0
while kill -0 "$bare_claim_pid" 2>/dev/null && [ "$bare_claim_seconds" -lt 20 ]; do sleep 1; bare_claim_seconds=$((bare_claim_seconds + 1)); done
if kill -0 "$bare_claim_pid" 2>/dev/null; then kill -9 "$bare_claim_pid"; wait "$bare_claim_pid" 2>/dev/null; bare_claim_code=124; else wait "$bare_claim_pid"; bare_claim_code=$?; fi
check "StewardClaimWithABareBaseOption_ExitsWithTheUsageCode: --base names no branch, so the claim is a usage error, not a loop" \
  '[ "$bare_claim_code" -eq 2 ]'

echo "base: a letter outside ASCII is refused in a UTF-8 locale too"
# A UTF-8 locale lets a letter outside ASCII through the ranges A-Za-z, so the refusal rows run
# in one. C and some C.UTF-8 builds refuse it with no check at all, so they would pass on nothing:
# the rows take the first installed UTF-8 locale that lets the letter through, and are skipped,
# said, when none does. A fresh repo, so a full pool cannot pass the item over in place of the
# name check.
# lets_the_letter_through <locale>: true when the ranges A-Za-z let the letter through there.
lets_the_letter_through() {
  [ "$(LC_ALL=$1 sh -c 'case "$1" in *[!A-Za-z0-9._/-]*) echo refused ;; *) echo let-through ;; esac' sh "$name_with_a_letter_outside_ascii" 2>/dev/null)" = let-through ]
}
locale_letting_the_letter_through=""
for candidate_locale in en_US.UTF-8 $(locale -a 2>/dev/null | grep -i 'utf-\{0,1\}8$'); do
  if lets_the_letter_through "$candidate_locale"; then locale_letting_the_letter_through="$candidate_locale"; break; fi
done
if [ -z "$locale_letting_the_letter_through" ]; then
  echo "  skip no installed UTF-8 locale lets a letter outside ASCII through the ranges, so the rows that refuse it in one cannot run here"
else
  new_repo accented
  remote_branch "$name_with_a_letter_outside_ascii"
  accented="$(new_task "Accented plan" "" "base: $name_with_a_letter_outside_ascii
$body")"
  LC_ALL=$locale_letting_the_letter_through "$plugin/scripts/next.sh" "$accented" >/dev/null 2>&1; accented_code=$?
  check "BaseLineWithALetterOutsideAsciiInAUnicodeLocale_ClaimsNoWorktree [$locale_letting_the_letter_through]: the branch is on the remote, but its name is refused whatever the locale" \
    '[ -z "$("$plugin/scripts/steward.sh" find "$accented")" ]'
  check "BaseLineWithALetterOutsideAsciiInAUnicodeLocale_NamedRunExitsWithThePassOverCode [$locale_letting_the_letter_through]: a refused base passes the item over like a missing one" \
    '[ "$accented_code" -eq 4 ]'
  check "BaseLineWithALetterOutsideAsciiInAUnicodeLocale_LastEventSaysTheNameIsNotValid [$locale_letting_the_letter_through]: the refusal is the name check, not a missing branch" \
    'state "$accented" last_event | grep -qF -- "$base_name_refused"'
  accented_direct="$(new_task "Accented direct claim")"
  LC_ALL=$locale_letting_the_letter_through "$plugin/scripts/steward.sh" claim "$accented_direct" --base "$name_with_a_letter_outside_ascii" >/dev/null 2>&1; accented_direct_code=$?
  check "StewardClaimWithALetterOutsideAsciiInAUnicodeLocale_ExitsWithTheUsageCode [$locale_letting_the_letter_through]: steward's own claim refuses the name whatever the locale" \
    '[ "$accented_direct_code" -eq 2 ]'
fi

echo "base: the epic walk stops at a parent id no adapter owns"
# A parent id with no adapter prefix is read as an adapter name, so a path there would run any
# read.sh it points at. The planted one leaves a mark when it runs.
new_repo stray
mkdir -p "$work/planted"
cat > "$work/planted/read.sh" <<PLANTED
#!/bin/sh
: > "$work/planted.ran"
echo '{"id": "planted", "kind": "epic", "parent": "", "state": {}}'
PLANTED
chmod +x "$work/planted/read.sh"
climb_to_the_root=""; for level in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do climb_to_the_root="$climb_to_the_root../"; done
parent_id_no_adapter_owns="$climb_to_the_root${work#/}/planted"
check "PlantedRead_RunsWhenCalled: the planted script leaves its mark, so its absence below means it never ran" \
  '"$work/planted/read.sh" >/dev/null && [ -e "$work/planted.ran" ] && rm -f "$work/planted.ran"'
stray="$("$local_adapter/create.sh" task "Stray child" --size S --body "$body" --parent "$parent_id_no_adapter_owns")"
"$plugin/scripts/next.sh" "$stray" >/dev/null 2>&1
check "ChildOfAParentIdNoAdapterOwns_RunsNothingAtThatPath: the walk stops at the id, so the file it names never runs" \
  '[ ! -e "$work/planted.ran" ]'
check "ChildOfAParentIdNoAdapterOwns_TakesTheConfigBase: the walk finds no epic past the id, so the claim falls through to the config base" \
  '[ "$(claim_base "$stray")" = main ]'

[ "$fails" -eq 0 ] && { echo "base-claim: ok"; exit 0; }
echo "base-claim: $fails failed"; exit 1
