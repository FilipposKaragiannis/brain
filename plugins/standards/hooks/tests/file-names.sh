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
run_hook() { printf '{"tool_input":{"command":"git commit -m x"}}' | "$hooks/$1" 2>"$work/stderr" >/dev/null; }
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
check "FormatLoop_LeadingDashNameIsOneIteration: the loop saw -dash.cs as one line" grep -qFx -e '-dash.cs' "$work/loop.log"
check "FormatLoop_CraftedNamesCreateNoFile: no name ran as a command" no_injection

[ "$fails" -eq 0 ] && echo "file-names: ok" || { echo "file-names: $fails failed"; exit 1; }
