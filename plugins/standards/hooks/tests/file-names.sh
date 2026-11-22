#!/bin/sh
# Tests that the commit hooks treat staged file names as data: names with a space, quotes, $( ), a
# backtick, a newline, a leading dash and other odd bytes reach the formatter as one argument each,
# the comment hook reads their own content, no name runs as a command, and check-range replays the
# same result. Builds a throwaway repo. Run from anywhere. Exit 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
hooks="$here/.."
work="$(mktemp -d)"
. "$hooks/../../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$hooks/.."
trap 'sandbox_close $?' EXIT
unset STANDARDS_FROM_GIT STANDARDS_STAGE STANDARDS_GATES STANDARDS_COMMIT_MESSAGE
mkdir -p "$work/offline"
for tool in curl wget gh osascript notify-send claude codex; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/offline.log"\n' "$tool" "$work" > "$work/offline/$tool"
  chmod +x "$work/offline/$tool"
done
PATH="$work/offline:$PATH"; export PATH
fails=0
hook_passes=0
hook_blocks=2
range_fails=1
fixture_comment_line=2
forged_fixture_comment_line=3
bad_content_report="validate: bad content"
newline_refusal="a file name with a newline cannot go into a quoted {files}"
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

names_do() {
  "$@" 'with space.cs'
  "$@" "it's.cs"
  "$@" 'it'\''$(touch${IFS}INJECTED)'\''s.cs'
  "$@" 'say "hi".cs'
  "$@" 'a$(touch${IFS}INJECTED).cs'
  "$@" 'a`touch INJECTEDTICK`.cs'
  "$@" "line1
line2.cs"
  "$@" '-dash.cs'
  "$@" "tab	name.cs"
  "$@" "$(printf 'carriage\rreturn.cs')"
  "$@" 'back\slash.cs'
  "$@" 'café.cs'
}
crafted_names_do() {
  "$@" 'it'\''$(touch${IFS}INJECTED)'\''s.cs'
  "$@" 'a$(touch${IFS}INJECTED).cs'
  "$@" 'a`touch INJECTEDTICK`.cs'
}
write_interface() { printf 'interface I {\n  /// doc\n  void M();\n}\n' > "$1"; }
write_line_comment() { printf 'class A {\n  // note\n}\n' > "$1"; }
write_bad_content() { mkdir -p "$(dirname -- "$1")"; printf 'class A {}\nBADCONTENT\n' > "$1"; }
write_tabs() { printf 'class Bad {\n\tTABS\n}\n' > "$1"; }
reset_to() { git reset -q --hard "$1" && git clean -qfdx; }
clear_markers() { rm -f INJECTED INJECTEDTICK "$work/INJECTED"; }
run_hook() { clear_markers; printf '{"tool_input":{"command":"git commit -m x"}}' | "$hooks/$1" 2>"$work/stderr" >/dev/null; }
run_range() { clear_markers; "$hooks/check-range.sh" --gates "$1" "$base" HEAD >"$work/range" 2>&1; }
stderr_names() { case "$(cat "$work/stderr")" in *"$1:$fixture_comment_line"*) return 0 ;; esac; return 1; }
no_injection() { [ ! -e INJECTED ] && [ ! -e INJECTEDTICK ] && [ ! -e "$work/INJECTED" ]; }
exited_with_report() { [ "$1" -eq "$2" ] && grep -qF -- "$3" "$4"; }
report_lists_line() { sed 's/^ *//' "$2" | grep -qxF -- "$1"; }
label_of() { printf '%s' "$1" | tr '\n\r' '  '; }
has_newline() { case "$1" in *"
"*) return 0 ;; esac; return 1; }

cat > "$work/validate.sh" <<'VALIDATE'
#!/bin/sh
[ "$#" -gt 0 ] || { echo "validate: no files"; exit 1; }
for file in "$@"; do
  [ -f "$file" ] || { echo "validate: not a file"; exit 1; }
  ! grep -q BADCONTENT -- "$file" || { echo "validate: bad content"; exit 1; }
done
VALIDATE

cd "$work" || exit
git init -q -b main repo && cd repo || exit
git config user.email t@t && git config user.name t
mkdir -p .standards
cat > .standards/config.json <<JSON
{
  "version": "0.1.0",
  "languages": [
    { "name": "csharp", "extensions": [".cs"],
      "format": [ { "prefix": "", "command": "sh $work/validate.sh {files}" } ],
      "comments": { "line": "//", "doc": "///", "public": "public", "doc_inside": ["interface", "enum"], "allow_markers": [] } }
  ],
  "build": "true",
  "protected": ["*space.cs", "-dash.cs"]
}
JSON
printf 'class Seed {}\n' > Seed.cs
git add -A && git commit -qm init
base="$(git rev-parse HEAD)"

write_config() { printf '{"version":"0.1.0","languages":[{"name":"csharp","extensions":[".cs"],"format":[{"prefix":"","command":%s}],"comments":{"line":"//","doc":"///","public":"public","doc_inside":["interface","enum"],"allow_markers":[]}},{"name":"shell","extensions":[".sh"],"format":[{"prefix":"","command":%s}]}],"build":"true"}\n' "$1" "$2" > .standards/config.json; }
loop_command="\"for f in {files}; do printf '[%s]\\\\n' \\\"\$f\\\" >> $work/loop.log; done\""
stage_every_name_and_run() { reset_to "$base"; names_do "$1"; git add -A; run_hook "$2"; }
run_format_hook() { git add -A && run_hook check-format.sh; }
run_comment_hook() { git add -A && run_hook check-comments.sh; }
replay_committed_range() { git add -A && git commit -qm "crafted name" && run_range "check-format check-comments"; }
crafted_name_runs_no_command() {
  reset_to "$1"
  write_interface "$4"
  "$2"
  check "$3_CraftedNameCreatesNoFile: $4 ran no command" no_injection
}

bad_name_blocks() {
  reset_to "$base"
  write_bad_content "$1"
  git add -A
  run_hook check-format.sh; bad_status=$?
  check "FormatCommand_BadContentBlocks: the formatter read the bad content of $(label_of "$1") and the hook blocked" \
    exited_with_report "$hook_blocks" "$bad_status" "$bad_content_report" "$work/stderr"
}

echo "check-format: names reach the formatter intact"
stage_every_name_and_run write_interface check-format.sh; format_status=$?
check "FormatCommand_SpecialNamesAreNotSplit: every argument the formatter got was a staged file, so the hook passed" [ "$format_status" -eq "$hook_passes" ]
names_do bad_name_blocks
crafted_names_do crafted_name_runs_no_command "$base" run_format_hook FormatCommand

echo "check-format: a path with a space"
reset_to "$base"
mkdir -p "dir with space"
printf 'class Pre {}\n' > "dir with space/Pre.cs"
git add -A
run_hook check-format.sh; path_clean_status=$?
check "FormatCommand_PathWithSpaceIsOneFile: the formatter found dir with space/Pre.cs as one file and the hook passed" [ "$path_clean_status" -eq "$hook_passes" ]
bad_name_blocks "dir with space/Pre.cs"

echo "check-comments: content is found by name"
stage_every_name_and_run write_interface check-comments.sh; interface_status=$?
check "CommentHook_DocOnInterfaceMemberPasses: every special name's content was found, so the doc is allowed" [ "$interface_status" -eq "$hook_passes" ]
crafted_names_do crafted_name_runs_no_command "$base" run_comment_hook CommentHook
stage_every_name_and_run write_line_comment check-comments.sh; line_status=$?
check "CommentHook_LineCommentBlocks: the commit is blocked" [ "$line_status" -eq "$hook_blocks" ]
comment_report_names() { check "CommentHook_LineCommentNamesTheFile: the report names $(label_of "$1") with its line" stderr_names "$1"; }
names_do comment_report_names

echo "check-config: names match protected patterns"
stage_every_name_and_run write_interface check-config.sh; config_status=$?
check "ConfigHook_ProtectedSpecialNamesBlock: the commit is blocked" [ "$config_status" -eq "$hook_blocks" ]
check "ConfigHook_SpaceNameIsReportedWhole: the report names with space.cs as one file" grep -qF '  with space.cs (matches *space.cs)' "$work/stderr"
check "ConfigHook_LeadingDashNameIsReported: the report names -dash.cs" grep -qF '  -dash.cs (matches -dash.cs)' "$work/stderr"

echo "check-range: the replay reads the same names"
reset_to "$base"
names_do write_interface
git add -A && git commit -qm "special names"
run_range "check-format"; range_format_status=$?
check "CheckRangeReplay_CleanCommitPassesTheFormatter: the replayed formatter found each special name as one file and check-range passed" [ "$range_format_status" -eq "$hook_passes" ]
run_range "check-comments"; range_comments_status=$?
check "CheckRangeReplay_CleanCommitPassesTheCommentHook: the replayed comment hook found each special name's content and check-range passed" [ "$range_comments_status" -eq "$hook_passes" ]
crafted_names_do crafted_name_runs_no_command "$base" replay_committed_range CheckRangeReplay
reset_to "$base"
write_bad_content 'with space.cs'
git add -A && git commit -qm "bad content"
run_range "check-format"; range_bad_status=$?
check "CheckRangeReplay_BadContentBlocks: the replayed formatter read the bad content of with space.cs and check-range failed" \
  exited_with_report "$range_fails" "$range_bad_status" "$bad_content_report" "$work/range"
reset_to "$base"
write_line_comment 'with space.cs'
git add -A && git commit -qm "commented"
run_range "check-comments"; range_comment_status=$?
check "CheckRangeReplay_LineCommentBlocks: check-range failed" [ "$range_comment_status" -eq "$range_fails" ]
check "CheckRangeReplay_LineCommentNamesTheFile: the replay report names with space.cs with its line" grep -qF "with space.cs:$fixture_comment_line" "$work/range"

echo "check-format: a loop over {files}"
reset_to "$base"
write_config "$loop_command" '""'
git add -A && git commit -qm "loop config"
loop_base="$(git rev-parse HEAD)"
rm -f "$work/loop.log"
names_do write_interface
git add -A
run_hook check-format.sh; loop_status=$?
check "FormatLoop_NormalCommitPasses: a for loop over {files} passed" [ "$loop_status" -eq "$hook_passes" ]
loop_saw_name() { case "$(cat "$work/loop.log")" in *"[$1]"*) return 0 ;; esac; return 1; }
loop_iteration() { check "FormatLoop_NameIsOneIteration: the loop saw $(label_of "$1") as one item" loop_saw_name "$1"; }
names_do loop_iteration
crafted_names_do crafted_name_runs_no_command "$loop_base" run_format_hook FormatLoop

nested_command='"sh -c '\''for f in {files}; do grep -q -e TABS -- \"$f\" && { printf \"tabs in %s\\n\" \"$f\"; exit 1; }; done; exit 0'\''"'
repo_command='"for f in {files}; do sh -n -- \"$f\" || exit 1; done"'

echo "check-format: a {files} inside a nested sh -c"
reset_to "$base"
write_config "$nested_command" '""'
git add -A && git commit -qm "nested config"
nested_base="$(git rev-parse HEAD)"
nested_clean_passes() {
  has_newline "$1" && return 0
  reset_to "$nested_base"
  write_interface "$1"
  git add -A
  run_hook check-format.sh; nested_clean_status=$?
  check "NestedFormatCommand_CleanNamePasses: the nested shell checked $(label_of "$1") and the hook passed" [ "$nested_clean_status" -eq "$hook_passes" ]
  check "NestedFormatCommand_CleanNameCreatesNoFile: $(label_of "$1") ran no command" no_injection
}
nested_bad_name_blocks() {
  has_newline "$1" && return 0
  reset_to "$nested_base"
  write_tabs "$1"
  git add -A
  run_hook check-format.sh; nested_bad_status=$?
  check "NestedFormatCommand_BadNameBlocks: the nested loop read the tabs in $(label_of "$1") as one file and the hook blocked" \
    exited_with_report "$hook_blocks" "$nested_bad_status" "tabs in $1" "$work/stderr"
  check "NestedFormatCommand_BadNameCreatesNoFile: the blocked $(label_of "$1") ran no command" no_injection
}
names_do nested_clean_passes
names_do nested_bad_name_blocks
reset_to "$nested_base"
write_interface "line1
line2.cs"
git add -A
run_hook check-format.sh; nested_newline_status=$?
check "NestedFormatCommand_NewlineNameBlocks: a name with a newline cannot go into a quoted {files}, so the hook blocked" \
  exited_with_report "$hook_blocks" "$nested_newline_status" "$newline_refusal" "$work/stderr"

echo "check-format: the repo's own format command"
reset_to "$base"
write_config '"true"' "$repo_command"
git add -A && git commit -qm "repo config"
repo_base="$(git rev-parse HEAD)"
printf 'echo ok\n' > 'my file.sh'
printf 'echo ok\n' > ./-dash.sh
git add -A
run_hook check-format.sh; repo_clean_status=$?
check "RepoFormatCommand_NormalCommitPasses: sh -n read my file.sh and -dash.sh as one file each and the hook passed" [ "$repo_clean_status" -eq "$hook_passes" ]
reset_to "$repo_base"
printf 'if then\n' > 'my file.sh'
git add -A
run_hook check-format.sh; repo_bad_status=$?
check "RepoFormatCommand_SyntaxErrorBlocks: sh -n reported the error in my file.sh and the hook blocked" \
  exited_with_report "$hook_blocks" "$repo_bad_status" "my file.sh: " "$work/stderr"
check "RepoFormatCommand_BlockReportNamesTheFile: the report lists my file.sh" report_lists_line 'my file.sh' "$work/stderr"

echo "check-comments: names come from git, not from the diff text"
reset_to "$base"
printf 'class Forge {\n++ forged.cs\n  // explains\n}\n' > Forge.cs
git add -A
run_hook check-comments.sh; forge_status=$?
check "CommentHook_ForgedHeaderLineStillBlocks: the line comment was reported and the hook blocked" [ "$forge_status" -eq "$hook_blocks" ]
check "CommentHook_ForgedHeaderLineKeepsTheRealName: the report names Forge.cs and not the forged name" \
  sh -c 'grep -qF "Forge.cs:$2" "$1" && ! grep -qF "forged.cs:" "$1"' sh "$work/stderr" "$forged_fixture_comment_line"

echo "check-comments: a file in a folder beside a root file"
reset_to "$base"
mkdir sub
write_line_comment sub/Nested.cs
git add -A
run_hook check-comments.sh
check "CommentHook_NestedFileIsCheckedBesideARootFile: Seed.cs at the root does not hide sub/Nested.cs" grep -qF "sub/Nested.cs:$fixture_comment_line" "$work/stderr"

echo "check-comments: a carriage return name does not borrow the content of a look-alike name"
reset_to "$base"
printf 'class Private {\n  /// doc\n  void M() {}\n}\n' > "$(printf 'A\r.cs')"
write_interface Ar.cs
git add -A
run_hook check-comments.sh; look_alike_status=$?
check "CommentHook_CarriageReturnNameKeepsItsOwnContent: the doc in the class named with a carriage return was reported although Ar.cs holds an interface" \
  exited_with_report "$hook_blocks" "$look_alike_status" "$(printf 'A\r.cs'):$fixture_comment_line" "$work/stderr"

echo "check-comments: a symlink replaced by a regular file"
reset_to "$base"
ln -s Seed.cs Linked.cs
git add -A && git commit -qm "symlink"
rm Linked.cs
write_line_comment Linked.cs
git add -A
run_hook check-comments.sh; type_change_status=$?
check "CommentHook_TypeChangedFileIsChecked: a line comment in a file that replaced a symlink blocks the commit" [ "$type_change_status" -eq "$hook_blocks" ]
check "CommentHook_TypeChangedFileIsNamed: the report names Linked.cs with its line" grep -qF "Linked.cs:$fixture_comment_line" "$work/stderr"

echo "check-gates: a special path matches the gate's paths"
reset_to "$base"
printf '{"version":"0.1.0","languages":[],"gates":[{"name":"ran","command":"echo ran >> %s/gate.log","paths":["src/*.cs"],"when":["commit"]}]}\n' "$work" > .standards/config.json
git add -A && git commit -qm "gate config"
gate_base="$(git rev-parse HEAD)"
gate_runs_for() {
  reset_to "$gate_base"
  mkdir -p src
  printf 'class A {}\n' > "src/$1"
  git add -A
  rm -f "$work/gate.log"
  run_hook check-gates.sh
  check "GateHook_SpecialNameMatchesPaths: the gate command ran for src/$(label_of "$1")" [ -s "$work/gate.log" ]
}
gate_runs_for 'a b.cs'
gate_runs_for 'é.cs'

[ "$fails" -eq 0 ] && echo "file-names: ok" || { echo "file-names: $fails failed"; exit 1; }
