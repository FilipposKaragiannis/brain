#!/bin/sh
# file-names.sh: the commit hooks treat staged file names as data. Names with a space, quotes,
# $( ), a backtick, a newline and a leading dash reach the formatter as one argument each, the
# comment hook finds their content, no name runs as a command, and check-range replays the same
# result. Exit 0 when every check passes, 1 on any failure. tools/test.sh runs it.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
hooks="$here/.."
work="$(mktemp -d)"
. "$hooks/../../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$hooks/.."
trap 'sandbox_close $?' EXIT
mkdir -p "$work/offline"
for tool in curl wget gh osascript notify-send claude codex; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/offline.log"\n' "$tool" "$work" > "$work/offline/$tool"
  chmod +x "$work/offline/$tool"
done
PATH="$work/offline:$PATH"; export PATH
fails=0
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
}
write_interface() { printf 'interface I {\n  /// doc\n  void M();\n}\n' > "$1"; }
write_line_comment() { printf 'class A {\n  // note\n}\n' > "$1"; }
clear_markers() { rm -f INJECTED INJECTEDTICK "$work/INJECTED"; }
run_hook() { clear_markers; printf '{"tool_input":{"command":"git commit -m x"}}' | "$hooks/$1" 2>"$work/stderr" >/dev/null; }
stderr_names() { case "$(cat "$work/stderr")" in *"$1:2"*) return 0 ;; esac; return 1; }
no_injection() { [ ! -e INJECTED ] && [ ! -e INJECTEDTICK ] && [ ! -e "$work/INJECTED" ]; }

cat > "$work/record.sh" <<'RECORD'
#!/bin/sh
printf '%s' "$#" > "$(dirname "$0")/count"
printf '%s\0' "$@" > "$(dirname "$0")/seen"
RECORD
cat > "$work/expected-names.sh" <<'EXPECTED'
#!/bin/sh
printf '%s\0' '-dash.cs' 'a$(touch${IFS}INJECTED).cs' 'a`touch INJECTEDTICK`.cs' \
  'it'\''$(touch${IFS}INJECTED)'\''s.cs' "it's.cs" "line1
line2.cs" 'say "hi".cs' 'with space.cs'
EXPECTED

cd "$work"
git init -q -b main repo && cd repo
git config user.email t@t && git config user.name t
mkdir -p .standards
cat > .standards/config.json <<JSON
{
  "version": "0.1.0",
  "languages": [
    { "name": "csharp", "extensions": [".cs"],
      "format": [ { "prefix": "", "command": "sh $work/record.sh {files}" } ],
      "comments": { "line": "//", "doc": "///", "public": "public", "doc_inside": ["interface", "enum"], "allow_markers": [] } }
  ],
  "build": "true",
  "protected": ["*space.cs", "-dash.cs"]
}
JSON
printf 'class Seed {}\n' > Seed.cs
git add -A && git commit -qm init
base="$(git rev-parse HEAD)"

echo "check-format: names reach the formatter intact"
names_do write_interface
git add -A
run_hook check-format.sh; format_status=$?
sh "$work/expected-names.sh" > "$work/expected"
check "FormatCommand_GetsEachSpecialNameAsOneArgument: the formatter saw the eight names byte for byte, one argument each" cmp -s "$work/seen" "$work/expected"
check "FormatCommand_CraftedNamesCreateNoFile: no name ran as a command" no_injection
check "FormatCommand_NormalCommitPasses: the hook exited 0 with the formatter content clean" [ "$format_status" -eq 0 ]

echo "check-comments: content is found by name"
run_hook check-comments.sh; interface_status=$?
check "CommentHook_DocOnInterfaceMemberPasses: every special name's content was found, so the doc is allowed" [ "$interface_status" -eq 0 ]
check "CommentHook_CraftedNamesCreateNoFile: no name ran as a command" no_injection
names_do write_line_comment
git add -A
run_hook check-comments.sh; line_status=$?
check "CommentHook_LineCommentBlocks: the commit is blocked" [ "$line_status" -eq 2 ]
for_each_hit() { check "CommentHook_LineCommentNamesTheFile: the report names $1 with its line" stderr_names "$1"; }
names_do for_each_hit

echo "check-config: names match protected patterns"
run_hook check-config.sh; config_status=$?
check "ConfigHook_ProtectedSpecialNamesBlock: the commit is blocked" [ "$config_status" -eq 2 ]
check "ConfigHook_SpaceNameIsReportedWhole: the report names with space.cs as one file" grep -qF '  with space.cs (matches *space.cs)' "$work/stderr"
check "ConfigHook_LeadingDashNameIsReported: the report names -dash.cs" grep -qF '  -dash.cs (matches -dash.cs)' "$work/stderr"

echo "check-range: the replay reads the same names"
names_do write_interface
git add -A && git commit -qm "special names" && rm -f "$work/seen"
clear_markers
"$hooks/check-range.sh" --gates "check-format check-comments" "$base" HEAD >"$work/range" 2>&1; range_status=$?
check "CheckRangeReplay_CleanCommitPasses: check-range exited 0" [ "$range_status" -eq 0 ]
check "CheckRangeReplay_FormatterGetsEachSpecialNameAsOneArgument: the replayed formatter saw the eight names byte for byte" cmp -s "$work/seen" "$work/expected"
check "CheckRangeReplay_CraftedNamesCreateNoFile: no name ran as a command" no_injection

echo "check-format: a path with a space"
git reset -q --hard "$base"
mkdir -p "dir with space"
printf 'class Pre {}\n' > "dir with space/Pre.cs"
git add -A
run_hook check-format.sh
check "FormatCommand_PathWithSpaceIsOneFile: the formatter got one argument" [ "$(cat "$work/count")" = 1 ]
printf '%s\0' 'dir with space/Pre.cs' > "$work/expected-path"
check "FormatCommand_PathWithSpaceKeepsItsName: the argument is the whole path byte for byte" cmp -s "$work/seen" "$work/expected-path"

echo "check-format: a loop over {files}"
git reset -q --hard "$base"
cat > .standards/config.json <<JSON
{
  "version": "0.1.0",
  "languages": [
    { "name": "csharp", "extensions": [".cs"],
      "format": [ { "prefix": "", "command": "for f in {files}; do printf '%s\\\\n' \"\$f\" >> $work/loop.log; done" } ] }
  ],
  "build": "true"
}
JSON
git add -A && git commit -qm "loop config"
names_do write_interface
git add -A
run_hook check-format.sh; loop_status=$?
check "FormatLoop_NormalCommitPasses: a for loop over {files} exited 0" [ "$loop_status" -eq 0 ]
check "FormatLoop_SpaceNameIsOneIteration: the loop saw with space.cs as one line" grep -qFx 'with space.cs' "$work/loop.log"
check "FormatLoop_QuoteBreakNameIsOneIteration: the loop saw the quote-break name as one line" grep -qFx 'it'\''$(touch${IFS}INJECTED)'\''s.cs' "$work/loop.log"
check "FormatLoop_DoubleQuoteNameIsOneIteration: the loop saw the double-quote name as one line" grep -qFx 'say "hi".cs' "$work/loop.log"
check "FormatLoop_CommandSubstitutionNameIsOneIteration: the loop saw the \$( ) name as one line" grep -qFx 'a$(touch${IFS}INJECTED).cs' "$work/loop.log"
check "FormatLoop_BacktickNameIsOneIteration: the loop saw the backtick name as one line" grep -qFx 'a`touch INJECTEDTICK`.cs' "$work/loop.log"
check "FormatLoop_NewlineNameIsOneIteration: the loop saw both halves of the newline name" sh -c 'grep -qFx line1 "$1" && grep -qFx line2.cs "$1"' sh "$work/loop.log"
check "FormatLoop_LeadingDashNameIsOneIteration: the loop saw -dash.cs as one line" grep -qFx -e '-dash.cs' "$work/loop.log"
check "FormatLoop_CraftedNamesCreateNoFile: no name ran as a command" no_injection

write_config() { printf '{"version":"0.1.0","languages":[{"name":"csharp","extensions":[".cs"],"format":[{"prefix":"","command":%s}],"comments":{"line":"//","doc":"///","public":"public","doc_inside":["interface","enum"],"allow_markers":[]}},{"name":"shell","extensions":[".sh"],"format":[{"prefix":"","command":%s}]}],"build":"true"}\n' "$1" "$2" > .standards/config.json; }
nested_command='"sh -c '\''for f in {files}; do grep -q TABS \"$f\" && exit 1; done; exit 0'\''"'
repo_command='"for f in {files}; do sh -n -- \"$f\" || exit 1; done"'

echo "check-format: a {files} inside a nested sh -c"
git reset -q --hard "$base"
write_config "$nested_command" '""'
git add -A && git commit -qm "nested config"
printf 'class Clean {}\n' > 'with space.cs'
printf 'class Clean {}\n' > 'a$(touch${IFS}INJECTED).cs'
printf 'class Clean {}\n' > "it's.cs"
printf 'class Clean {}\n' > 'say "hi".cs'
git add -A
run_hook check-format.sh; nested_clean_status=$?
check "NestedFormatCommand_CleanNamesPass: the nested shell checked every name and the hook exited 0" [ "$nested_clean_status" -eq 0 ]
check "NestedFormatCommand_CraftedNamesCreateNoFile: no name ran as a command" no_injection
printf 'class Bad {\n\tTABS\n}\n' > 'a$(touch${IFS}INJECTED).cs'
git add -A
run_hook check-format.sh; nested_bad_status=$?
check "NestedFormatCommand_BadFileBlocks: the nested shell saw the crafted name and the hook exited 2" [ "$nested_bad_status" -eq 2 ]
check "NestedFormatCommand_BadFileCreatesNoFile: the blocked name ran no command" no_injection
check "NestedFormatCommand_BlockReportNamesTheFile: the report lists the failing name" grep -qF '    a$(touch${IFS}INJECTED).cs' "$work/stderr"
printf 'class Bad {\n\tTABS\n}\n' > 'with space.cs'
git add -A
run_hook check-format.sh
check "NestedFormatCommand_SpaceNameIsOneWord: the nested loop read with space.cs as one file and blocked" grep -qF '    with space.cs' "$work/stderr"
git reset -q --hard && git clean -qfd
printf 'class Clean {}\n' > "line1
line2.cs"
git add -A
run_hook check-format.sh; nested_newline_status=$?
check "NestedFormatCommand_NewlineNameBlocks: a name with a newline cannot go into a quoted {files}, so the hook exited 2" [ "$nested_newline_status" -eq 2 ]

echo "check-format: the repo's own format command"
git reset -q --hard "$base"
write_config '"true"' "$repo_command"
git add -A && git commit -qm "repo config"
printf 'echo ok\n' > 'my file.sh'
printf 'echo ok\n' > ./-dash.sh
git add -A
run_hook check-format.sh; repo_clean_status=$?
check "RepoFormatCommand_NormalCommitPasses: sh -n read my file.sh and -dash.sh as one file each and the hook exited 0" [ "$repo_clean_status" -eq 0 ]
printf 'if then\n' > 'my file.sh'
git add -A
run_hook check-format.sh; repo_bad_status=$?
check "RepoFormatCommand_SyntaxErrorBlocks: sh -n failed on my file.sh and the hook exited 2" [ "$repo_bad_status" -eq 2 ]
check "RepoFormatCommand_BlockReportNamesTheFile: the report lists my file.sh" grep -qF '    my file.sh' "$work/stderr"

echo "check-comments: names come from git, not from the diff text"
git reset -q --hard "$base"
mkdir sub
printf 'class Forge {\n++ forged.cs\n  // explains\n}\n' > sub/Forge.cs
git add -A
run_hook check-comments.sh; forge_status=$?
check "CommentHook_ForgedHeaderLineStillBlocks: the line comment was reported and the hook exited 2" [ "$forge_status" -eq 2 ]
check "CommentHook_ForgedHeaderLineKeepsTheRealName: the report names sub/Forge.cs and not the forged name" sh -c 'grep -qF "sub/Forge.cs:3" "$1" && ! grep -qF "forged.cs:" "$1"' sh "$work/stderr"
check "CommentHook_NestedFileIsCheckedBesideARootFile: a root .cs file does not hide sub/Forge.cs" grep -qF 'sub/Forge.cs' "$work/stderr"

echo "check-range: a line comment in a special name blocks"
git reset -q --hard "$base"
printf 'class A {\n  // note\n}\n' > 'with space.cs'
git add -A && git commit -qm "commented"
clear_markers
"$hooks/check-range.sh" --gates "check-comments" "$base" HEAD >"$work/range" 2>&1; range_comment_status=$?
check "CheckRangeReplay_LineCommentBlocks: check-range exited 1" [ "$range_comment_status" -eq 1 ]
check "CheckRangeReplay_LineCommentNamesTheFile: the replay report names with space.cs with its line" grep -qF 'with space.cs:2' "$work/range"

echo "check-gates: a path with a space matches the gate's paths"
git reset -q --hard "$base"
mkdir src
cat > .standards/config.json <<JSON
{
  "version": "0.1.0",
  "languages": [],
  "gates": [ { "name": "ran", "command": "echo ran >> $work/gate.log", "paths": ["src/*.cs"], "when": ["commit"] } ]
}
JSON
git add -A && git commit -qm "gate config"
printf 'class A {}\n' > 'src/a b.cs'
git add -A
rm -f "$work/gate.log"
run_hook check-gates.sh
check "GateHook_SpaceNameMatchesPaths: the gate command ran for src/a b.cs" [ -s "$work/gate.log" ]
git reset -q --hard && git clean -qfd
mkdir -p src
printf 'class A {}\n' > 'src/é.cs'
git add -A
rm -f "$work/gate.log"
run_hook check-gates.sh
check "GateHook_NonAsciiNameMatchesPaths: the gate command ran for src/é.cs" [ -s "$work/gate.log" ]

[ "$fails" -eq 0 ] && echo "file-names: ok" || { echo "file-names: $fails failed"; exit 1; }
