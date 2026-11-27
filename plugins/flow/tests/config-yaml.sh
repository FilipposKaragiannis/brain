#!/bin/sh
# config-yaml.sh: the config migration's line editor, through the helper's plan and apply, one
# process per case file in fixtures/config-yaml/ (the input, and the file apply must write beside
# it as <case>.expected.yaml), on the step list there, the move-* cases on move-steps.json and the
# spread-* cases on spread-steps.json. Comments, a parent left empty, a map made or holding only
# comments, the label, line endings, the files refused whole, plan writing nothing, a moved key's
# block, and leaves spread into the maps absent. Takes no argument. Exit 0 when every check passes,
# 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$P"
work="$(mktemp -d)"
. "$P/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$P"
trap 'sandbox_close $?' EXIT
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { check_name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$check_name"; else fail "$check_name"; fi; }

helper="$P/scripts/_config_migration.py"
cases="$here/fixtures/config-yaml"
steps="$cases/steps.json"
new_label=9.9.9
nothing_to_change_exit=0
changed_exit=1
cannot_exit=2
out="$work/out.yaml"
carriage_return="$(printf '\r')"

# apply_exit <config file>: apply's exit code, its out file left at $out.
apply_exit() { rm -f "$out"; python3 -I "$helper" apply "$steps" "$1" "$new_label" "$out" >/dev/null 2>&1; echo "$?"; }
# writes_expected <case>: apply writes exactly the case's expected file.
writes_expected() { apply_exit "$cases/$1.yaml" >/dev/null; cmp -s "$cases/$1.expected.yaml" "$out"; }
# refused_whole <case>: apply exits as one that cannot migrate the case.
refused_whole() { [ "$(apply_exit "$cases/$1.yaml")" = "$cannot_exit" ]; }
# label_found <config file>: the first line plan prints.
label_found() { python3 -I "$helper" plan "$steps" "$1" "$new_label" 2>/dev/null | head -n 1; }
# every_line_ends_in_a_carriage_return <file>
every_line_ends_in_a_carriage_return() { [ "$(grep -c "$carriage_return\$" "$1")" = "$(grep -c '' "$1")" ]; }
# last_byte_is_not_a_newline <file>
last_byte_is_not_a_newline() { [ -n "$(tail -c 1 "$1")" ]; }

echo "comments and the parent of a removed key"
check "Apply_ChangesToMake_ExitsOne: a file with changes exits one, because init reads the exit code to know a backup and report are due" [ "$(apply_exit "$cases/comments-around-a-removed-key.yaml")" = "$changed_exit" ]
check "Apply_CommentsAroundARemovedKey_StayWhereTheyWere: comments keep their place, because the owner's notes are theirs" writes_expected comments-around-a-removed-key
check "Apply_TrailingCommentOnARemovedLine_StaysAsACommentLine: the comment outlives its line, because the owner's notes are theirs" writes_expected trailing-comment-on-a-removed-line
check "Apply_ParentLeftEmpty_GoesWithItsLastKey: the emptied parent goes too, because an empty map reads as a setting nobody made" writes_expected parent-left-empty
check "Apply_ParentWithATrailingComment_Stays: a commented parent stays, because removing it would drop the owner's note" writes_expected parent-with-a-trailing-comment

echo "an added key"
check "Apply_MapHoldingOnlyComments_GetsTheKeyAfterThem: the key goes below the comments, because those comments introduce the map" writes_expected map-holding-only-comments
check "Apply_MapAbsent_IsMadeAtTheEndOfTheFile: the new map goes last, because the owner's layout above stays as written" writes_expected map-absent
check "Apply_KeyPresentAndEmpty_IsNotOverwritten: an empty value stays, because the owner chose it" writes_expected key-present-and-empty
check "Apply_ValuesTheReadersTake_StayAsWritten: every value the readers parse is kept byte for byte, because a rewritten value could read differently" writes_expected values-the-readers-take

echo "the label"
check "Apply_LabelWithAComment_KeepsTheComment: the label's comment stays, because the owner's notes are theirs" writes_expected label-with-a-comment
check "Apply_LabelAbsent_IsAddedWithItsComment: the label comes with its comment, because the comment tells the owner what the label is for" writes_expected label-absent
check "Plan_LabelledFile_PrintsTheLabelFirst: plan names the label found, because init names the backup after it" [ "$(label_found "$cases/parent-left-empty.yaml")" = 1.40.0 ]
check "Plan_LabelAbsent_PrintsUnversionedFirst: plan says unversioned, because the backup still needs a name" [ "$(label_found "$cases/label-absent.yaml")" = unversioned ]
printf 'base: main\nconfig_version: ../../x/y\n' > "$work/label-with-slashes.yaml"
check "Plan_LabelWithSlashes_PrintsANameWithoutThem: no slash reaches the name, because a slash would write the backup outside the migrations folder" sh -c "label=\"\$1\"; [ -n \"\$label\" ] && case \"\$label\" in */*) false ;; esac" _ "$(label_found "$work/label-with-slashes.yaml")"

echo "nothing to change, and plan"
check "Apply_NothingToChange_ExitsZero: an up-to-date file exits zero, because init then writes no backup and no report" [ "$(apply_exit "$cases/nothing-to-change.yaml")" = "$nothing_to_change_exit" ]
apply_exit "$cases/nothing-to-change.yaml" >/dev/null
check "Apply_NothingToChange_WritesNoOutFile: no out file appears, because init would take it for a migrated config" [ ! -e "$out" ]
writes_expected parent-left-empty
cp "$out" "$work/migrated-once.yaml"
check "Apply_SecondRun_ChangesNothing: a migrated file has nothing left, because init runs again on every update" [ "$(apply_exit "$work/migrated-once.yaml")" = "$nothing_to_change_exit" ]
mkdir -p "$work/plan-only" && cp "$cases/parent-left-empty.yaml" "$work/plan-only/config.yaml"
(cd "$work/plan-only" && python3 -I "$helper" plan "$steps" config.yaml "$new_label" >/dev/null 2>&1)
check "Plan_ChangesPending_WritesNoOtherFile: plan creates no file, because plan is the dry run and must not write" [ "$(cd "$work/plan-only" && find . | sort)" = "$(printf '.\n./config.yaml\n')" ]
check "Plan_ChangesPending_LeavesTheConfig: plan leaves the config as it was, because plan is the dry run and must not write" cmp -s "$cases/parent-left-empty.yaml" "$work/plan-only/config.yaml"
printf '{"steps": [{"name": "later", "op": "rename", "key": "retro.commit", "reason": "r"}]}\n' > "$work/unknown-op.json"
check "Plan_StepWithAnUnknownOp_ExitsTwo: an unknown op is refused, because guessing could damage the owner's config" sh -c "python3 -I '$helper' plan '$work/unknown-op.json' '$cases/parent-left-empty.yaml' '$new_label' >/dev/null 2>&1; [ \$? = '$cannot_exit' ]"

echo "line endings"
printf 'base: main\r\nretro:\r\n  commit: false\r\n' > "$work/crlf.yaml"
apply_exit "$work/crlf.yaml" >/dev/null
check "Apply_CrlfFile_WritesANonEmptyFile: the CRLF file keeps its content, because an empty config loses every setting" [ -s "$out" ]
check "Apply_CrlfFile_EveryLineKeepsCrlf: every line still ends in CRLF, because mixed endings show the whole file as changed" every_line_ends_in_a_carriage_return "$out"
printf 'base: main\nretro:\n  commit: false' > "$work/unterminated.yaml"
apply_exit "$work/unterminated.yaml" >/dev/null
check "Apply_NoFinalNewline_StaysUnterminated: no newline is added at the end, because only what a step touches changes" last_byte_is_not_a_newline "$out"
printf 'base: main\r\nretro:\r\n  commit: false' > "$work/crlf-unterminated.yaml"
apply_exit "$work/crlf-unterminated.yaml" >/dev/null
check "Apply_CrlfFileWithoutFinalNewline_EveryTerminatedLineTakesCrlf: each ended line keeps CRLF and the last stays open, because mixed endings show the whole file as changed" sh -c "[ \"\$(grep -c '$carriage_return\$' '$out')\" = \"\$(( \$(grep -c '' '$out') - 1 ))\" ]"

echo "files outside the subset are refused whole"
check "Apply_TabIndentation_IsRefused: tabs are refused, because a guessed edit could break the owner's config" refused_whole refuse-tab-indentation
check "Apply_OddIndentation_IsRefused: odd indents are refused, because a guessed edit could break the owner's config" refused_whole refuse-odd-indentation
check "Apply_LineNeitherKeyNorItem_IsRefused: an unknown line shape is refused, because a guessed edit could break the owner's config" refused_whole refuse-neither-key-nor-item
check "Apply_KeyTwiceInOneMap_IsRefused: a key set twice is refused, because no one can tell which value the owner meant" refused_whole refuse-key-twice-in-one-map
check "Apply_ListItemOfNoKey_IsRefused: a stray list item is refused, because a guessed edit could break the owner's config" refused_whole refuse-item-of-no-key
check "Apply_KeyTwoLevelsDeeper_IsRefused: a jump of two levels is refused, because a guessed edit could break the owner's config" refused_whole refuse-key-two-levels-deeper
apply_exit "$cases/refuse-tab-indentation.yaml" >/dev/null
check "Apply_RefusedFile_WritesNoOutFile: a refused file leaves no out file, because init would take it for a migrated config" [ ! -e "$out" ]

echo "a moved key"
steps="$cases/move-steps.json"
check "Apply_MoveOfABlockList_CarriesItsItemsAndTrailingComments: the list moves whole, because a lost item changes the setting" writes_expected move-block-list
check "Apply_MoveTargetPresentAndEmpty_TargetWins: the owner's new key stays, because the owner's own setting wins" writes_expected move-target-present-and-empty
check "Apply_MoveIntoAMapHoldingOnlyComments_PutsTheKeyAfterThem: the key goes below the comments, because those comments introduce the map" writes_expected move-into-a-map-holding-only-comments
check "Apply_MoveLeavingItsParentEmpty_RemovesTheParent: the emptied parent goes, because an empty map reads as a setting nobody made" writes_expected move-parent-left-empty
check "Apply_MoveAcrossDepths_ReindentsTheBlockByTheDifference: the block is reindented as a whole, because a wrong indent changes what the readers see" writes_expected move-across-depths
writes_expected move-parent-left-empty
cp "$out" "$work/moved-once.yaml"
check "Apply_MoveRunTwice_SecondRunChangesNothing: a moved file has nothing left, because init runs again on every update" [ "$(apply_exit "$work/moved-once.yaml")" = "$nothing_to_change_exit" ]
printf 'base: main\r\ngithub:\r\n  ready_needs: [size]' > "$work/move-crlf.yaml"
apply_exit "$work/move-crlf.yaml" >/dev/null
check "Apply_MoveInACrlfFile_WritesANonEmptyFile: the CRLF file keeps its content, because an empty config loses every setting" [ -s "$out" ]
check "Apply_MoveInACrlfFileWithoutFinalNewline_EveryTerminatedLineTakesCrlf: each ended line keeps CRLF and the last stays open, because mixed endings show the whole file as changed" sh -c "[ \"\$(grep -c '$carriage_return\$' '$out')\" = \"\$(( \$(grep -c '' '$out') - 1 ))\" ]"
printf '{"steps": [{"name": "inside", "op": "move", "from": "ready", "to": "ready.needs", "reason": "r"}]}\n' > "$work/move-inside-itself.json"
check "Plan_MoveIntoItself_ExitsTwo: a move into its own child is refused, because it would delete the value it moves" sh -c "python3 -I '$helper' plan '$work/move-inside-itself.json' '$cases/move-parent-left-empty.yaml' '$new_label' >/dev/null 2>&1; [ \$? = '$cannot_exit' ]"

echo "leaves spread into each map"
steps="$cases/spread-steps.json"
check "Apply_SpreadIntoAbsentMaps_CopiesTheLeavesIntoEachMap: each map gets the leaves, because every host must keep the setting it had" writes_expected spread-no-host-maps
check "Apply_SpreadWithAnEmptyMapThere_WritesOnlyTheAbsentOne: the owner's empty map stays, because the owner's own setting wins" writes_expected spread-claude-map-empty
check "Apply_SpreadWithEveryMapThere_LeavesTheOldCommentsAsCommentLines: the old keys' comments stay, because the owner's notes are theirs" writes_expected spread-both-host-maps
check "Apply_SpreadOfANameOutsideTheTable_CopiesItAsWritten: an unmapped value is copied as is, because a guessed value could break the jobs" writes_expected spread-name-outside-the-table
check "Apply_SpreadOfABlockListWithAMappedItem_MapsTheItemLineInTheTablesMap: the codex copy's item line takes the table's value and the claude copy keeps it, because the readers take the item line's value as the key's" writes_expected spread-block-list-mapped
check "Apply_SpreadOfABlockListWithAnUnmappedItem_CopiesItAsWritten: both copies keep the item line, because a value outside the table is not changed" writes_expected spread-block-list-unmapped
check "Apply_SpreadOfAnInlineList_MapsItsOneValue: the codex copy's list holds the table's value, because the readers take [opus] as opus" writes_expected spread-inline-list
writes_expected spread-no-host-maps
cp "$out" "$work/spread-once.yaml"
check "Apply_SpreadRunTwice_SecondRunChangesNothing: a spread file has nothing left, because init runs again on every update" [ "$(apply_exit "$work/spread-once.yaml")" = "$nothing_to_change_exit" ]
printf 'base: main\r\njobs:\r\n  effort: high' > "$work/spread-crlf.yaml"
apply_exit "$work/spread-crlf.yaml" >/dev/null
check "Apply_SpreadInACrlfFile_WritesANonEmptyFile: the CRLF file keeps its content, because an empty config loses every setting" [ -s "$out" ]
check "Apply_SpreadInACrlfFileWithoutFinalNewline_EveryTerminatedLineTakesCrlf: each ended line keeps CRLF and the last stays open, because mixed endings show the whole file as changed" sh -c "[ \"\$(grep -c '$carriage_return\$' '$out')\" = \"\$(( \$(grep -c '' '$out') - 1 ))\" ]"
printf '{"steps": [{"name": "outside", "op": "spread", "from": "jobs", "keys": ["model"], "to": ["hosts.claude"], "reason": "r"}]}\n' > "$work/spread-outside.json"
check "Plan_SpreadIntoAMapOutsideItsFrom_ExitsTwo: a target outside the source map is refused, because the step list has a bug and must not run" sh -c "python3 -I '$helper' plan '$work/spread-outside.json' '$cases/spread-name-outside-the-table.yaml' '$new_label' >/dev/null 2>&1; [ \$? = '$cannot_exit' ]"
printf '{"steps": [{"name": "stray", "op": "spread", "from": "jobs", "keys": ["model"], "to": ["jobs.claude"], "values": {"jobs.codex.model": {"opus": "x"}}, "reason": "r"}]}\n' > "$work/spread-stray-values.json"
check "Plan_SpreadWithValuesForAKeyItDoesNotWrite_ExitsTwo: a value table for no target is refused, because the step list has a bug and must not run" sh -c "python3 -I '$helper' plan '$work/spread-stray-values.json' '$cases/spread-name-outside-the-table.yaml' '$new_label' >/dev/null 2>&1; [ \$? = '$cannot_exit' ]"

[ "$fails" -eq 0 ] && { echo "config-yaml: ok"; exit 0; }
echo "config-yaml: $fails failed"; exit 1
