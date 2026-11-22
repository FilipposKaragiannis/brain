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
single_quote_name="q'uote.name"
double_quote_name='d"quote.name'
subshell_name='$(touch pwned-subshell).name'
backtick_name='`touch pwned-backtick`.name'
semicolon_name=';touch pwned-semicolon.name'
ampersand_name='&amp.name'
pipe_name='|pipe.name'
dash_name='-dash.name'
glob_name='glob*[a].name'
hostile_names_total=9
unit_separator="$(printf '\037')"
spaced_names_total=2

configure() {
  rm -f "$received"
  mkdir -p "$worktree/.standards"
  python3 -c 'import json,sys; json.dump({"version": "1", "build": "", "test": [], "mutation": sys.argv[3], "languages": [{"name": "text", "extensions": json.loads(sys.argv[4]), "format": [{"prefix": "", "command": sys.argv[2]}]}]}, open(sys.argv[1], "w"))' \
    "$worktree/.standards/config.json" "$1" "$2" "${3:-[\".name\"]}"
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
changed_files_hold_whole() {
  python3 -c 'import json,sys; files=json.load(open(sys.argv[1]))["changed_files"]; sys.exit(not (sys.argv[2] in files and sys.argv[3] not in files))' "$reports/verify.json" "$1" "$2"
}
arrives_intact() {
  probe_name="$1"
  check "$2: it is data, so it reaches the command as one argument, byte for byte" 'received_has "$probe_name"'
}

new_item spaced ""
configure 'printf "%s\n" {files} > '"'$received'" ""
add_names 'a b.name' 'sub dir/c d.name'
verify >/dev/null
check "NameWithSpace_ArrivesAsOneArgument: a split name would check no file" \
  'received_has "a b.name" && received_has "sub dir/c d.name" && [ "$(received_total)" -eq "$spaced_names_total" ]'

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
printf "x\n" > "$worktree/gone.name" && git -C "$worktree" add -A && git -C "$worktree" commit -qm gone
add_names kept.name
rm "$worktree/gone.name"
verify >/dev/null
check "DeletedFile_IsNotPassed: a formatter cannot read a file that is gone" \
  '[ "$(cat "$received")" = kept.name ]'

new_item reading ""
configure "[ \"\$#\" -eq $hostile_names_total ] || { echo \"got \$# names\" >&2; exit 1; }; for name in {files}; do [ -f \"\$name\" ] || { echo \"missing \$name\" >&2; exit 1; }; done; echo read-every-name > '$received'" ""
add_hostile_names
verify >/dev/null
reading_result=$?
check "FormatterThatReadsEveryHostileName_PassesVerify: each name is one argument and the path of a real file" \
  '[ "$reading_result" -eq 0 ] && [ "$(check_field status format)" = pass ] && [ "$(cat "$received")" = read-every-name ]'

new_item failing ""
configure 'for name in {files}; do case "$name" in *fail*) echo "cannot format $name" >&2; exit 1 ;; esac; done' ""
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
configure 'true' 'true {files}; echo "mutants survived" >&2; exit 1'
add_names 'm n.name'
verify >/dev/null
check "MutationFailing_IsASignal: a failing mutation run is never a silent pass" \
  '[ "$(check_field status mutation)" = signal ]'
check "MutationFailing_GivesItsReason: the report carries what the command said" \
  'check_field summary mutation | grep -qF "mutants survived"'

new_item nestedsingle ""
configure "sh -c 'for name in {files}; do printf \"%s\\n\" \"\$name\" >> \"$received\"; done'" ""
add_hostile_names
verify >/dev/null
check "FilesInsideSingleQuotes_GiveTheNestedShellEveryName: the names are escaped for it" \
  '[ "$(received_total)" -eq "$hostile_names_total" ] && received_has "$subshell_name" && received_has "$single_quote_name" && received_has "$double_quote_name" && received_has "$semicolon_name"'
check "FilesInsideSingleQuotes_RunNothingAndCreateNoFile: an escaped name stays a name" \
  '[ -s "$received" ] && [ "$(untracked_names)" = "$(hostile_names_sorted)" ]'

new_item nesteddouble ""
configure "sh -c \"for name in {files}; do printf '%s\\n' \\\"\\\$name\\\" >> '$received'; done\"" ""
add_hostile_names
verify >/dev/null
check "FilesInsideDoubleQuotes_GiveTheNestedShellEveryName: the names are escaped for it" \
  '[ "$(received_total)" -eq "$hostile_names_total" ] && received_has "$subshell_name" && received_has "$single_quote_name" && received_has "$backtick_name" && received_has "$pipe_name"'

new_item emptycommand ""
configure '' ""
add_names kept.name
verify >/dev/null
empty_result=$?
check "EmptyFormatCommand_FailsVerify: a config verify cannot use is never a pass" \
  '[ "$empty_result" -eq 1 ] && [ "$(report_status)" = fail ]'
check "EmptyFormatCommand_NamesTheCheck: the report says which check failed" \
  '[ "$(failed_checks)" = format ]'
check "EmptyFormatCommand_GivesItsReason: the report says why the check failed" \
  'check_field summary format | grep -qi empty'

new_item newline ""
configure "sh -c 'for name in {files}; do echo \"\$name\"; done'" ""
add_names "line
break.name"
verify >/dev/null
newline_result=$?
check "NewlineNameInQuotedFiles_FailsVerify: a name that cannot be escaped is never dropped silently" \
  '[ "$newline_result" -eq 1 ] && [ "$(report_status)" = fail ]'
check "NewlineNameInQuotedFiles_NamesTheCheck: the report says which check failed" \
  '[ "$(failed_checks)" = format ]'
check "NewlineNameInQuotedFiles_GivesItsReason: the report says why" \
  'check_field summary format | grep -qi newline'

new_item separator ""
configure 'true' ""
add_names "a${unit_separator}b.name"
verify >/dev/null
separator_result=$?
check "NameWithUnitSeparator_FailsVerify: a name verify cannot hand on is never a silent pass" \
  '[ "$separator_result" -eq 1 ] && [ "$(report_status)" = fail ]'
check "NameWithUnitSeparator_NamesTheChangedFilesCheck: the report says which check failed" \
  '[ "$(failed_checks)" = "changed files" ]'

new_item noextensions ""
configure 'true' "" '[]'
add_names kept.name
verify >/dev/null
noextensions_result=$?
check "FormatCommandWithNoExtensions_FailsVerify: verify cannot tell which files it covers, so it never passes" \
  '[ "$noextensions_result" -eq 1 ] && [ "$(report_status)" = fail ]'
check "FormatCommandWithNoExtensions_NamesTheCheck: the report says which check failed" \
  '[ "$(failed_checks)" = format ]'
check "FormatCommandWithNoExtensions_GivesItsReason: the report says the extensions are missing" \
  'check_field summary format | grep -qi extensions'

new_item nestedtoodeep ""
configure "sh -c 'sh -c \"true {files}\"'" ""
add_names kept.name
verify >/dev/null
nestedtoodeep_result=$?
check "FilesInsideNestedQuotes_FailsVerify: the names could not stay data through two shells, so the check never passes" \
  '[ "$nestedtoodeep_result" -eq 1 ] && [ "$(report_status)" = fail ]'
check "FilesInsideNestedQuotes_NamesTheCheck: the report says which check failed" \
  '[ "$(failed_checks)" = format ]'
check "FilesInsideNestedQuotes_GivesItsReason: the report says to pass the names on as arguments" \
  'check_field summary format | grep -qF nested'

new_item escapedinnerquote ""
configure "sh -c 'printf \"%s\\n\" \"quote\\\"word\" > /dev/null; printf \"%s\\n\" {files} > \"$received\"'" ""
add_names kept.name
verify >/dev/null
escapedinnerquote_result=$?
check "EscapedQuoteInsideTheNestedShellsQuotes_KeepsFilesOutsideThem: the check runs and passes" \
  '[ "$escapedinnerquote_result" -eq 0 ] && received_has kept.name'

new_item reportedcommand ""
configure 'true {files}' ""
add_names kept.name
verify >/dev/null
check "FormatCheck_ReportsTheConfiguredCommand: the report shows the command as written, not the names it ran on" \
  '[ "$(check_field command format)" = "true {files}" ]'

new_item mutatingspaced ""
configure 'true' "printf '%s\\n' {files} > '$received'"
printf "x\n" > "$worktree/gone.name" && git -C "$worktree" add -A && git -C "$worktree" commit -qm gone
add_names 'm n.name'
rm "$worktree/gone.name"
verify >/dev/null
check "MutationWithFiles_GetsANameWithASpaceAsOneArgument: a split name would mutate no file" \
  'received_has "m n.name"'
check "MutationWithFiles_DoesNotPassADeletedFile: a mutation tool cannot read a file that is gone" \
  '[ -s "$received" ] && ! received_has gone.name'

new_item newlinescope '  guarded:
    command: '"'false'"'
    paths: [src/**/*.cs]'
configure 'true' ""
newline_scoped_name="src/x
y.cs"
add_names "$newline_scoped_name"
verify >/dev/null
newlinescope_result=$?
check "NewlineNameUnderAGatesPaths_RunsTheGate: a name is matched whole, so the gate is not skipped" \
  '[ "$newlinescope_result" -eq 1 ] && [ "$(failed_checks)" = "gate guarded" ]'
check "NewlineName_IsOneChangedFileInTheReport: the evidence lists only paths that changed" \
  'changed_files_hold_whole "$newline_scoped_name" src/x'
exit "$((fails > 0))"
