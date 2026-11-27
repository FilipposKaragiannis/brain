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
check "Apply_ChangesToMake_ExitsOne" [ "$(apply_exit "$cases/comments-around-a-removed-key.yaml")" = "$changed_exit" ]
check "Apply_CommentsAroundARemovedKey_StayWhereTheyWere" writes_expected comments-around-a-removed-key
check "Apply_TrailingCommentOnARemovedLine_StaysAsACommentLine" writes_expected trailing-comment-on-a-removed-line
check "Apply_ParentLeftEmpty_GoesWithItsLastKey" writes_expected parent-left-empty
check "Apply_ParentWithATrailingComment_Stays" writes_expected parent-with-a-trailing-comment

echo "an added key"
check "Apply_MapHoldingOnlyComments_GetsTheKeyAfterThem" writes_expected map-holding-only-comments
check "Apply_MapAbsent_IsMadeAtTheEndOfTheFile" writes_expected map-absent
check "Apply_KeyPresentAndEmpty_IsNotOverwritten" writes_expected key-present-and-empty
check "Apply_ValuesTheReadersTake_StayAsWritten" writes_expected values-the-readers-take

echo "the label"
check "Apply_LabelWithAComment_KeepsTheComment" writes_expected label-with-a-comment
check "Apply_LabelAbsent_IsAddedWithItsComment" writes_expected label-absent
check "Plan_LabelledFile_PrintsTheLabelFirst" [ "$(label_found "$cases/parent-left-empty.yaml")" = 1.40.0 ]
check "Plan_LabelAbsent_PrintsUnversionedFirst" [ "$(label_found "$cases/label-absent.yaml")" = unversioned ]
printf 'base: main\nconfig_version: ../../x/y\n' > "$work/label-with-slashes.yaml"
check "Plan_LabelWithSlashes_PrintsANameWithoutThem" sh -c "label=\"\$1\"; [ -n \"\$label\" ] && case \"\$label\" in */*) false ;; esac" _ "$(label_found "$work/label-with-slashes.yaml")"

echo "nothing to change, and plan"
check "Apply_NothingToChange_ExitsZero" [ "$(apply_exit "$cases/nothing-to-change.yaml")" = "$nothing_to_change_exit" ]
apply_exit "$cases/nothing-to-change.yaml" >/dev/null
check "Apply_NothingToChange_WritesNoOutFile" [ ! -e "$out" ]
writes_expected parent-left-empty
cp "$out" "$work/migrated-once.yaml"
check "Apply_SecondRun_ChangesNothing" [ "$(apply_exit "$work/migrated-once.yaml")" = "$nothing_to_change_exit" ]
mkdir -p "$work/plan-only" && cp "$cases/parent-left-empty.yaml" "$work/plan-only/config.yaml"
(cd "$work/plan-only" && python3 -I "$helper" plan "$steps" config.yaml "$new_label" >/dev/null 2>&1)
check "Plan_ChangesPending_WritesNoOtherFile" [ "$(cd "$work/plan-only" && find . | sort)" = "$(printf '.\n./config.yaml\n')" ]
check "Plan_ChangesPending_LeavesTheConfig" cmp -s "$cases/parent-left-empty.yaml" "$work/plan-only/config.yaml"
printf '{"steps": [{"name": "later", "op": "rename", "key": "retro.commit", "reason": "r"}]}\n' > "$work/unknown-op.json"
check "Plan_StepWithAnUnknownOp_ExitsTwo" sh -c "python3 -I '$helper' plan '$work/unknown-op.json' '$cases/parent-left-empty.yaml' '$new_label' >/dev/null 2>&1; [ \$? = '$cannot_exit' ]"

echo "line endings"
printf 'base: main\r\nretro:\r\n  commit: false\r\n' > "$work/crlf.yaml"
apply_exit "$work/crlf.yaml" >/dev/null
check "Apply_CrlfFile_WritesANonEmptyFile" [ -s "$out" ]
check "Apply_CrlfFile_EveryLineKeepsCrlf" every_line_ends_in_a_carriage_return "$out"
printf 'base: main\nretro:\n  commit: false' > "$work/unterminated.yaml"
apply_exit "$work/unterminated.yaml" >/dev/null
check "Apply_NoFinalNewline_StaysUnterminated" last_byte_is_not_a_newline "$out"
printf 'base: main\r\nretro:\r\n  commit: false' > "$work/crlf-unterminated.yaml"
apply_exit "$work/crlf-unterminated.yaml" >/dev/null
check "Apply_CrlfFileWithoutFinalNewline_EveryTerminatedLineTakesCrlf" sh -c "[ \"\$(grep -c '$carriage_return\$' '$out')\" = \"\$(( \$(grep -c '' '$out') - 1 ))\" ]"

echo "files outside the subset are refused whole"
check "Apply_TabIndentation_IsRefused" refused_whole refuse-tab-indentation
check "Apply_OddIndentation_IsRefused" refused_whole refuse-odd-indentation
check "Apply_LineNeitherKeyNorItem_IsRefused" refused_whole refuse-neither-key-nor-item
check "Apply_KeyTwiceInOneMap_IsRefused" refused_whole refuse-key-twice-in-one-map
check "Apply_ListItemOfNoKey_IsRefused" refused_whole refuse-item-of-no-key
check "Apply_KeyTwoLevelsDeeper_IsRefused" refused_whole refuse-key-two-levels-deeper
apply_exit "$cases/refuse-tab-indentation.yaml" >/dev/null
check "Apply_RefusedFile_WritesNoOutFile" [ ! -e "$out" ]

echo "a moved key"
steps="$cases/move-steps.json"
check "Apply_MoveOfABlockList_CarriesItsItemsAndTrailingComments" writes_expected move-block-list
check "Apply_MoveTargetPresentAndEmpty_TargetWins" writes_expected move-target-present-and-empty
check "Apply_MoveIntoAMapHoldingOnlyComments_PutsTheKeyAfterThem" writes_expected move-into-a-map-holding-only-comments
check "Apply_MoveLeavingItsParentEmpty_RemovesTheParent" writes_expected move-parent-left-empty
check "Apply_MoveAcrossDepths_ReindentsTheBlockByTheDifference" writes_expected move-across-depths
writes_expected move-parent-left-empty
cp "$out" "$work/moved-once.yaml"
check "Apply_MoveRunTwice_SecondRunChangesNothing" [ "$(apply_exit "$work/moved-once.yaml")" = "$nothing_to_change_exit" ]
printf 'base: main\r\ngithub:\r\n  ready_needs: [size]' > "$work/move-crlf.yaml"
apply_exit "$work/move-crlf.yaml" >/dev/null
check "Apply_MoveInACrlfFile_WritesANonEmptyFile" [ -s "$out" ]
check "Apply_MoveInACrlfFileWithoutFinalNewline_EveryTerminatedLineTakesCrlf" sh -c "[ \"\$(grep -c '$carriage_return\$' '$out')\" = \"\$(( \$(grep -c '' '$out') - 1 ))\" ]"
printf '{"steps": [{"name": "inside", "op": "move", "from": "ready", "to": "ready.needs", "reason": "r"}]}\n' > "$work/move-inside-itself.json"
check "Plan_MoveIntoItself_ExitsTwo" sh -c "python3 -I '$helper' plan '$work/move-inside-itself.json' '$cases/move-parent-left-empty.yaml' '$new_label' >/dev/null 2>&1; [ \$? = '$cannot_exit' ]"

echo "leaves spread into each map"
steps="$cases/spread-steps.json"
check "Apply_SpreadIntoAbsentMaps_CopiesTheLeavesIntoEachMap" writes_expected spread-no-host-maps
check "Apply_SpreadWithAnEmptyMapThere_WritesOnlyTheAbsentOne" writes_expected spread-claude-map-empty
check "Apply_SpreadWithEveryMapThere_LeavesTheOldCommentsAsCommentLines" writes_expected spread-both-host-maps
check "Apply_SpreadOfANameOutsideTheTable_CopiesItAsWritten" writes_expected spread-name-outside-the-table
writes_expected spread-no-host-maps
cp "$out" "$work/spread-once.yaml"
check "Apply_SpreadRunTwice_SecondRunChangesNothing" [ "$(apply_exit "$work/spread-once.yaml")" = "$nothing_to_change_exit" ]
printf 'base: main\r\njobs:\r\n  effort: high' > "$work/spread-crlf.yaml"
apply_exit "$work/spread-crlf.yaml" >/dev/null
check "Apply_SpreadInACrlfFile_WritesANonEmptyFile" [ -s "$out" ]
check "Apply_SpreadInACrlfFileWithoutFinalNewline_EveryTerminatedLineTakesCrlf" sh -c "[ \"\$(grep -c '$carriage_return\$' '$out')\" = \"\$(( \$(grep -c '' '$out') - 1 ))\" ]"
printf '{"steps": [{"name": "outside", "op": "spread", "from": "jobs", "keys": ["model"], "to": ["hosts.claude"], "reason": "r"}]}\n' > "$work/spread-outside.json"
check "Plan_SpreadIntoAMapOutsideItsFrom_ExitsTwo" sh -c "python3 -I '$helper' plan '$work/spread-outside.json' '$cases/spread-name-outside-the-table.yaml' '$new_label' >/dev/null 2>&1; [ \$? = '$cannot_exit' ]"
printf '{"steps": [{"name": "stray", "op": "spread", "from": "jobs", "keys": ["model"], "to": ["jobs.claude"], "values": {"jobs.codex.model": {"opus": "x"}}, "reason": "r"}]}\n' > "$work/spread-stray-values.json"
check "Plan_SpreadWithValuesForAKeyItDoesNotWrite_ExitsTwo" sh -c "python3 -I '$helper' plan '$work/spread-stray-values.json' '$cases/spread-name-outside-the-table.yaml' '$new_label' >/dev/null 2>&1; [ \$? = '$cannot_exit' ]"

[ "$fails" -eq 0 ] && { echo "config-yaml: ok"; exit 0; }
echo "config-yaml: $fails failed"; exit 1
