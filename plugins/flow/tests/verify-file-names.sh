#!/bin/sh
# verify-file-names.sh: how verify hands changed file names to a format or mutation command, in
# throwaway repos. A name arrives as one argument whatever characters it holds, and runs nothing;
# {files} outside quotes is the names as arguments, inside quotes the names escaped for the nested
# shell; a command verify cannot run is a failed check that says why.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
. "$here/_verify_fixture.sh"

LC_ALL=C; export LC_ALL
received="$work/received"
single_quote_name="q'uote.nm"
double_quote_name='d"quote.nm'
subshell_name='$(touch pwned-subshell).nm'
backtick_name='`touch pwned-backtick`.nm'
semicolon_name=';touch pwned-semicolon.nm'
ampersand_name='&amp.nm'
pipe_name='|pipe.nm'
dash_name='-dash.nm'
glob_name='glob*[a].nm'
hostile_names_total=9

configure() {
  rm -f "$received"
  mkdir -p "$worktree/.standards"
  python3 -c 'import json,sys; json.dump({"version": "1", "build": "", "test": [], "mutation": sys.argv[3], "languages": [{"name": "text", "extensions": [".nm"], "format": [{"prefix": "", "command": sys.argv[2]}]}]}, open(sys.argv[1], "w"))' \
    "$worktree/.standards/config.json" "$1" "$2"
  git -C "$worktree" add -A && git -C "$worktree" commit -qm "config"
}
add_names() { for added_name in "$@"; do mkdir -p "$(dirname "$worktree/$added_name")"; printf 'x\n' > "$worktree/$added_name"; done; }
add_hostile_names() {
  add_names "$single_quote_name" "$double_quote_name" "$subshell_name" "$backtick_name" "$semicolon_name" \
    "$ampersand_name" "$pipe_name" "$dash_name" "$glob_name"
}
received_total() { grep -c '' "$received"; }
received_has() { grep -qxF -e "$1" "$received"; }
untracked_names() { git -C "$worktree" ls-files -z --others | tr '\0' '\n' | grep -v '^\.flow/' | sort; }
hostile_names_sorted() {
  printf '%s\n' "$single_quote_name" "$double_quote_name" "$subshell_name" "$backtick_name" "$semicolon_name" \
    "$ampersand_name" "$pipe_name" "$dash_name" "$glob_name" | sort
}
check_field() { python3 -c 'import json,sys; print(next(check[sys.argv[2]] for check in json.load(open(sys.argv[1]))["checks"] if check["name"] == sys.argv[3]))' "$reports/verify.json" "$1" "$2"; }
arrives_intact() {
  probe_name="$1"
  check "$2: it is data, so it reaches the command as one argument, byte for byte" 'received_has "$probe_name"'
}

new_item spaced ""
configure 'printf "%s\n" {files} > '"'$received'" ""
add_names 'a b.nm' 'sub dir/c d.nm'
verify >/dev/null
check "NameWithSpace_ArrivesAsOneArgument: a split name would check no file" \
  'received_has "a b.nm" && received_has "sub dir/c d.nm" && [ "$(received_total)" -eq 2 ]'

new_item hostile ""
configure 'printf "%s\n" {files} > '"'$received'" ""
add_hostile_names
verify >/dev/null
arrives_intact "$single_quote_name" "NameWithSingleQuote_ArrivesIntact"
arrives_intact "$double_quote_name" "NameWithDoubleQuote_ArrivesIntact"
arrives_intact "$subshell_name" "NameWithCommandSubstitution_ArrivesIntact"
arrives_intact "$backtick_name" "NameWithBackticks_ArrivesIntact"
arrives_intact "$semicolon_name" "NameWithSemicolon_ArrivesIntact"
arrives_intact "$ampersand_name" "NameWithAmpersand_ArrivesIntact"
arrives_intact "$pipe_name" "NameWithPipe_ArrivesIntact"
arrives_intact "$dash_name" "NameWithLeadingDash_ArrivesIntact"
arrives_intact "$glob_name" "NameWithGlobCharacters_ArrivesIntact"
check "HostileNames_ArriveAsExactlyOneArgumentEach: nothing is split or merged" \
  '[ "$(received_total)" -eq "$hostile_names_total" ]'
check "HostileNames_RunNothingAndCreateNoFile: no name may become a command, and the run must have happened" \
  '[ -s "$received" ] && [ "$(untracked_names)" = "$(hostile_names_sorted)" ]'

new_item deleted ""
configure 'printf "%s\n" {files} > '"'$received'" ""
printf "x\n" > "$worktree/gone.nm" && git -C "$worktree" add -A && git -C "$worktree" commit -qm gone
add_names kept.nm
rm "$worktree/gone.nm"
verify >/dev/null
check "DeletedFile_IsNotPassed: a formatter cannot read a file that is gone" \
  '[ "$(cat "$received")" = kept.nm ]'

new_item reading ""
configure "[ \"\$#\" -eq $hostile_names_total ] || { echo \"got \$# names\" >&2; exit 1; }; for f in {files}; do [ -f \"\$f\" ] || { echo \"missing \$f\" >&2; exit 1; }; done; echo read-every-name > '$received'" ""
add_hostile_names
verify >/dev/null
reading_result=$?
check "FormatterThatReadsEveryHostileName_PassesVerify: each name is one argument and the path of a real file" \
  '[ "$reading_result" -eq 0 ] && [ "$(check_field status format)" = pass ] && [ "$(cat "$received")" = read-every-name ]'

new_item failing ""
configure 'for f in {files}; do case "$f" in *fail*) echo "cannot format $f" >&2; exit 1 ;; esac; done' ""
add_names "fail $subshell_name" "fine $ampersand_name"
verify >/dev/null
failing_result=$?
check "FormatterFailingOnAHostileName_FailsVerify: the check cannot pass without checking the file" \
  '[ "$failing_result" -eq 1 ] && [ "$(report_status)" = fail ]'
check "FormatterFailingOnAHostileName_NamesTheCheck: the report says which check failed" \
  '[ "$(failed_checks)" = format ]'
check "FormatterFailingOnAHostileName_GivesItsReason: the report carries what the command said" \
  'check_field summary format | grep -qF "cannot format fail $subshell_name"'
check "FormatterFailingOnAHostileName_RunsNothingTheNameHolds: a name is never command text" \
  '[ ! -e "$worktree/pwned-subshell" ]'

new_item mutating ""
configure 'true' "printf '%s\\n' {files} > '$received'"
add_hostile_names
verify >/dev/null
check "MutationWithFiles_GetsEveryNameAsOneArgument: it is read like a format command" \
  '[ "$(received_total)" -eq "$hostile_names_total" ] && received_has "$subshell_name" && received_has "$dash_name" && received_has "$ampersand_name"'
check "MutationWithFiles_RunsNothingAndCreatesNoFile: no name may become a command" \
  '[ -s "$received" ] && [ "$(untracked_names)" = "$(hostile_names_sorted)" ]'

new_item mutationfailing ""
configure 'true' 'echo "mutants survived" >&2; exit 1; # {files}'
add_names 'm n.nm'
verify >/dev/null
check "MutationFailing_ShowsAsASignalWithItsReason: a failing mutation run is never a silent pass" \
  '[ "$(check_field status mutation)" = signal ] && check_field summary mutation | grep -qF "mutants survived"'

new_item nestedsingle ""
configure "sh -c 'for f in {files}; do printf \"%s\\n\" \"\$f\" >> \"$received\"; done'" ""
add_hostile_names
verify >/dev/null
check "FilesInsideSingleQuotes_GiveTheNestedShellEveryName: the names are escaped for it" \
  '[ "$(received_total)" -eq "$hostile_names_total" ] && received_has "$subshell_name" && received_has "$single_quote_name" && received_has "$double_quote_name" && received_has "$semicolon_name"'
check "FilesInsideSingleQuotes_RunNothingAndCreateNoFile: an escaped name stays a name" \
  '[ -s "$received" ] && [ "$(untracked_names)" = "$(hostile_names_sorted)" ]'

new_item nesteddouble ""
configure "sh -c \"for f in {files}; do printf '%s\\n' \\\"\\\$f\\\" >> '$received'; done\"" ""
add_hostile_names
verify >/dev/null
check "FilesInsideDoubleQuotes_GiveTheNestedShellEveryName: the names are escaped for it" \
  '[ "$(received_total)" -eq "$hostile_names_total" ] && received_has "$subshell_name" && received_has "$single_quote_name" && received_has "$backtick_name" && received_has "$pipe_name"'

new_item emptycommand ""
configure '' ""
add_names kept.nm
verify >/dev/null
empty_result=$?
check "EmptyFormatCommand_FailsVerifyAndNamesTheCheck: a config verify cannot use is never a pass" \
  '[ "$empty_result" -eq 1 ] && [ "$(failed_checks)" = format ]'
check "EmptyFormatCommand_GivesItsReason: the report says why the check failed" \
  'check_field summary format | grep -qi empty'

new_item newline ""
configure "sh -c 'for f in {files}; do echo \"\$f\"; done'" ""
add_names "line
break.nm"
verify >/dev/null
newline_result=$?
check "NewlineNameInQuotedFiles_FailsTheCheckWithItsReason: a name that cannot be escaped is never dropped silently" \
  '[ "$newline_result" -eq 1 ] && [ "$(failed_checks)" = format ] && check_field summary format | grep -qi newline'
exit "$((fails > 0))"
