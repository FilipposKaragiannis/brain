#!/bin/sh
# verify-file-names.sh: how verify hands changed file names to a format or mutation command, in
# throwaway repos. A name arrives as one argument whatever characters it holds; {files} outside
# quotes is the names as arguments, inside quotes the names escaped for the nested shell.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
. "$here/_verify_fixture.sh"

received="$work/received"
# configure <format command> <mutation command>: commits .standards/config.json in the worktree.
configure() {
  rm -f "$received"
  mkdir -p "$worktree/.standards"
  python3 -c 'import json,sys; json.dump({"version": "1", "build": "", "test": [], "mutation": sys.argv[3], "languages": [{"name": "text", "extensions": [".nm"], "format": [{"prefix": "", "command": sys.argv[2]}]}]}, open(sys.argv[1], "w"))' \
    "$worktree/.standards/config.json" "$1" "$2"
  git -C "$worktree" add -A && git -C "$worktree" commit -qm "config"
}
# add_names <name>...: a changed text file for each name.
add_names() { for added_name in "$@"; do printf 'x\n' > "$worktree/$added_name"; done; }

new_item spaced ""
configure 'printf "%s\n" {files} > '"'$received'" ""
add_names 'a b.nm'
verify >/dev/null
check "NameWithSpace_ArrivesAsOneArgument because a split name would check no file" \
  '[ "$(grep -c "" "$received")" -eq 1 ] && grep -qx "a b.nm" "$received"'

new_item hostile ""
configure 'printf "%s\n" {files} > '"'$received'" ""
add_names "q'uote.nm" 'd"quote.nm' '$(touch pwned-subshell).nm' '`touch pwned-backtick`.nm' ';touch pwned-semicolon.nm' '&amp.nm' '|pipe.nm' '-dash.nm'
verify >/dev/null
check "HostileNames_ArriveIntact because a name is data and never command text" \
  '[ "$(grep -c "" "$received")" -eq 8 ] && grep -qxF "q'"'"'uote.nm" "$received" && grep -qxF "\$(touch pwned-subshell).nm" "$received" && grep -qxF -e "-dash.nm" "$received" && grep -qxF "&amp.nm" "$received"'
check "HostileNames_RunNothing because no name may become a command" \
  '[ ! -e "$worktree/pwned-subshell" ] && [ ! -e "$worktree/pwned-backtick" ] && [ ! -e "$worktree/pwned-semicolon.nm" ] && [ ! -e "$worktree/touch" ]'

new_item deleted ""
configure 'printf "%s\n" {files} > '"'$received'" ""
printf "x\n" > "$worktree/gone.nm" && git -C "$worktree" add -A && git -C "$worktree" commit -qm gone
add_names kept.nm
rm "$worktree/gone.nm"
verify >/dev/null
check "DeletedFile_IsNotPassed because a formatter cannot read a file that is gone" \
  '[ "$(cat "$received")" = kept.nm ]'

new_item failing ""
configure 'for f in {files}; do case "$f" in *fail*) exit 1 ;; esac; done' ""
add_names 'fail me.nm'
verify >/dev/null
failing_result=$?
check "FormatterFailingOnAHostileName_FailsVerifyAndNamesTheCheck because the report must show it" \
  '[ "$failing_result" -eq 1 ] && [ "$(failed_checks)" = format ]'

new_item mutating ""
configure 'true' "printf '%s\\n' {files} > '$received'"
add_names 'm n.nm' '$(touch pwned-mutation).nm'
verify >/dev/null
check "MutationWithFiles_GetsTheNamesAsArguments because it is read like a format command" \
  '[ "$(grep -c "" "$received")" -eq 2 ] && grep -qxF "m n.nm" "$received" && [ ! -e "$worktree/pwned-mutation" ]'

new_item nested ""
configure "sh -c 'for f in {files}; do printf \"%s\\n\" \"\$f\" >> \"$received\"; done'" ""
add_names 'n m.nm' '$(touch pwned-nested).nm'
verify >/dev/null
check "QuotedFilesPlaceholder_GivesTheNestedShellEachName because the names are escaped for it" \
  '[ "$(grep -c "" "$received")" -eq 2 ] && grep -qxF "n m.nm" "$received" && [ ! -e "$worktree/pwned-nested" ]'
exit "$((fails > 0))"
