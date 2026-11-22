#!/bin/sh
# Tests the {files} placeholder helper against a real sh and bash. It generates configured commands
# over the outer quoting (none, or the single- or double-quoted script of a sh -c or a bash -c), the
# quoting {files} sits in inside it (none, single, double), an escape or quote before {files} or
# inside those quotes, the spacing and text joined after {files}, expands each with hostile file
# names and runs the result as the hooks and verify do. A spacing puts one blank, two blanks or a
# space and a tab between the shell and -c, between -c and the script and before {files}, each run
# once at each place, or a tab or a newline before {files}. Each of ; & | < > ( ) and a newline also
# sits directly before {files} and, but for (, directly after it. Every command must be refused, or
# deliver every name intact as one word and run nothing. Run from anywhere. Exit 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
hooks="$here/.."
work="$(mktemp -d)"
. "$hooks/../../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$hooks/.."
trap 'sandbox_close $?' EXIT
. "$hooks/files_placeholder.sh"
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

received="$work/received"; expected="$work/expected"; run_folder="$work/run"; broken="$work/broken"
outcomes="$work/outcomes"; tab="$(printf '\t')"; newline='
'; space=' '
mkdir -p "$work/bin"
for recorder in record dotnet npx; do
  printf '#!/bin/sh\nprintf "%%s\\n" "$@" >> "%s"\n' "$received" > "$work/bin/$recorder" && chmod +x "$work/bin/$recorder"
done
PATH="$work/bin:$PATH"; export PATH
with_hostile_names() {
  "$@" 'a b.name' "it's.name" 'say"hi.name' '$(touch pwned-dollar).name' '`touch pwned-tick`.name' ';touch pwned-semicolon.name'
}
with_hostile_names printf '%s\n' > "$expected"
names_total="$(grep -c '' "$expected")"

fragments() {
  cat <<'FRAGMENTS'

\'
\"
"a\"b"
"a'b"
'a"b'
FRAGMENTS
}

inner_quote() {
  case "$1" in single) printf "'" ;; double) printf '"' ;; esac
}

script_text() {
  script_quote="$(inner_quote "$1")"
  case "$2" in
    inside) printf 'record %s %s%s%s{files}%s' "$3" "$script_quote" "$4" "$5" "$script_quote" ;;
    after) printf 'record %s %s%s%s%s{files}' "$3" "$script_quote" "$4" "$script_quote" "$5" ;;
    joined) printf 'record %s %s%s%s{files}' "$3" "$script_quote" "$4" "$script_quote" ;;
    followed) printf 'record %s %s%s%s{files}x%s' "$3" "$script_quote" "$4" "$5" "$script_quote" ;;
  esac
}

shell_gap() {
  case "$1" in two) printf '%s' "$space$space" ;; mixed) printf '%s' "$space$tab" ;; *) printf '%s' "$space" ;; esac
}

script_gap() {
  case "$1" in one) printf '%s' "$space$space" ;; two) printf '%s' "$space$tab" ;; *) printf '%s' "$space" ;; esac
}

files_gap() {
  case "$1" in
    one) printf '%s' "$space$tab" ;; two) printf '%s' "$space" ;; mixed) printf '%s' "$space$space" ;;
    tab) printf '%s' "$tab" ;; newline) printf '%s' "$newline" ;;
  esac
}

configured_command() {
  configured_shell_gap="$(shell_gap "$3")"; configured_script_gap="$(script_gap "$3")"
  case "$1" in
    *-single) printf "%s%s-c%s'%s'" "${1%-*}" "$configured_shell_gap" "$configured_script_gap" "$2" ;;
    *-double) printf '%s%s-c%s"%s"' "${1%-*}" "$configured_shell_gap" "$configured_script_gap" "$2" ;;
    *) printf '%s' "$2" ;;
  esac
}

outer_quotings="none sh-single sh-double"
if command -v bash >/dev/null 2>&1; then
  outer_quotings="$outer_quotings bash-single bash-double"
else
  echo "  skip bash -c cases: bash is not installed"
fi

fragment_commands() {
  fragment_outer="$1"; fragment_inner="$2"; fragment_placement="$3"; fragment_spacing="$4"
  fragment_blank="$(files_gap "$fragment_spacing")."; fragment_blank="${fragment_blank%.}"
  fragments | while IFS= read -r fragment; do
    tally_outcome "$(configured_command "$fragment_outer" "$(script_text "$fragment_inner" "$fragment_placement" "$fragment" "" "$fragment_blank")" "$fragment_spacing")"
    [ "$fragment_inner" = none ] || [ -z "$fragment" ] && continue
    tally_outcome "$(configured_command "$fragment_outer" "$(script_text "$fragment_inner" "$fragment_placement" "" "$fragment" "$fragment_blank")" "$fragment_spacing")"
  done
}

blank_commands() {
  [ "$3" = joined ] && { fragment_commands "$1" "$2" "$3" joined; return; }
  for spacing in one two mixed tab newline; do fragment_commands "$1" "$2" "$3" "$spacing"; done
}

placement_commands() {
  placement_outer="$1"; placement_inner="$2"
  for placement in after inside joined followed; do
    [ "$placement_inner:$placement" = none:inside ] && continue
    blank_commands "$placement_outer" "$placement_inner" "$placement"
  done
}

inner_quoting_commands() {
  for inner_quoting in none single double; do placement_commands "$1" "$inner_quoting"; done
}

operator_before_files() {
  printf 'record x%s{files}' "$1"
}

operator_after_files() {
  case "$1" in
    '<'|'>') printf 'record {files}%s/dev/null' "$1" ;;
    ')') printf '(record {files})' ;;
    *) printf 'record {files}%swait' "$1" ;;
  esac
}

operator_commands() {
  for operator in ';' '&' '|' '<' '>' '(' ')' "$newline"; do
    tally_outcome "$(configured_command "$1" "$(operator_before_files "$operator")" one)"
    [ "$operator" = '(' ] || tally_outcome "$(configured_command "$1" "$(operator_after_files "$operator")" one)"
  done
}

tally_generated_commands() {
  for generated_outer in $outer_quotings; do
    inner_quoting_commands "$generated_outer"; operator_commands "$generated_outer"
  done
}

run_expanded() {
  run_in="$1"; run_command="$2"; shift 2
  (cd "$run_in" && format_names_escaped="$(names_backslash_escaped "$@")" sh -c "$run_command" sh "$@") >/dev/null 2>&1
}

outcome() {
  outcome_expanded="$(files_placeholder_expanded "$1" 2>/dev/null)" || { echo refused; return 0; }
  rm -rf "$run_folder" && mkdir "$run_folder" && : > "$received"
  with_hostile_names run_expanded "$run_folder" "$outcome_expanded"
  if tail -n "$names_total" "$received" | cmp -s - "$expected" && [ -z "$(ls -A "$run_folder")" ]; then echo intact; else echo broken; fi
}

tally_outcome() {
  tally_result="$(outcome "$1")"
  printf '%s\n' "$tally_result" >> "$outcomes"
  if [ "$tally_result" = broken ]; then printf '%s\n' "$1" >> "$broken"; fi
}

: > "$broken"; : > "$outcomes"
tally_generated_commands
generated_total="$(grep -c '' "$outcomes")"; delivered_total="$(grep -c '^intact$' "$outcomes")"
echo "files placeholder: $generated_total generated commands, $delivered_total delivered, the rest refused"
sed 's/^/    broken: /' "$broken"
check "GeneratedCommand_IsRefusedOrDeliversEveryNameIntact: no generated command runs a name or changes one" [ ! -s "$broken" ]
check "GeneratedCommands_AreNotAllRefused: the scanner still hands names to commands it can read" [ "$delivered_total" -gt 0 ]

delivers() { [ "$(outcome "$1")" = intact ]; }
refuses() { [ "$(outcome "$1")" = refused ]; }
check "FilesAsAnArgument_DeliversEveryName: the names are arguments" delivers 'record {files}'
check "FilesInASingleQuotedScript_DeliversEveryName: the nested shell reads escaped names" delivers "sh -c 'record {files}'"
check "FilesInADoubleQuotedScript_DeliversEveryName: the nested shell reads escaped names" delivers 'sh -c "record {files}"'
check "EscapedDoubleQuoteInsideTheScriptsSingleQuotes_KeepsFilesInTheScript: the outer shell's escape is not a closing quote" \
  delivers "sh -c \"record 'a\\\"b' {files}\""
check "EscapedQuoteBeforeFiles_DeliversEveryName: an escaped quote opens no quote" delivers "record \\' {files}"
check "EscapedQuoteBeforeFilesInAScript_DeliversEveryName: the nested shell's escaped quote opens no quote" \
  delivers "sh -c 'record \\\" {files}'"
check "FilesJoinedToTheScriptAfterItsQuote_IsRefused: the first name would be script text" refuses "sh -c 'record '{files}"
check "FilesInNestedQuotes_IsRefused: two shells would read the names" refuses "sh -c 'sh -c \"record {files}\"'"
check "FilesAfterADotnetSolution_DeliversEveryName: the names follow the solution's arguments" \
  delivers 'dotnet format style X.sln --include {files}'
check "FilesAfterAnNpxCommand_DeliversEveryName: the names follow the tool's arguments" delivers 'npx prettier --check {files}'
check "FilesInAForLoop_DeliversEveryName: the loop reads each name as one word" \
  delivers 'for name in {files}; do record "$name" || exit 1; done'

syntax_folder="$work/syntax"; unparsable_script='unclosed.name'
syntax_check_loop='for name in {files}; do sh -n "$name" || exit 1; done'
write_parsable_scripts() {
  rm -rf "$syntax_folder" && mkdir "$syntax_folder" || return 1
  for script_name in "$@"; do printf 'true\n' > "$syntax_folder/$script_name" || return 1; done
}
syntax_checks_pass() {
  syntax_expanded="$(files_placeholder_expanded "$syntax_check_loop" 2>/dev/null)" || return 1
  with_hostile_names write_parsable_scripts && with_hostile_names run_expanded "$syntax_folder" "$syntax_expanded"
}
syntax_checks_fail_on_the_unparsable_script() {
  syntax_expanded="$(files_placeholder_expanded "$syntax_check_loop" 2>/dev/null)" || return 1
  with_hostile_names write_parsable_scripts && printf 'if true; then\n' > "$syntax_folder/$unparsable_script" || return 1
  ! with_hostile_names run_expanded "$syntax_folder" "$syntax_expanded" "$unparsable_script"
}
check "FilesInAForLoopOfSyntaxChecks_PassesWhenEveryNamedScriptParses: each name reaches sh -n as the path of its file" \
  syntax_checks_pass
check "FilesInAForLoopOfSyntaxChecks_FailsWhenANamedScriptDoesNotParse: the check reads the scripts it is given" \
  syntax_checks_fail_on_the_unparsable_script
check "FilesInAZshScript_IsRefused: only sh and bash read the script by the scanned rules" refuses "zsh -c 'record {files}'"

project="$work/project"
delivers_in_project() {
  project_expanded="$(files_placeholder_expanded "$1" 2>/dev/null)" || return 1
  rm -rf "$project" && mkdir -p "$project/scripts" && echo 'activated=yes' > "$project/scripts/activate" || return 1
  : > "$received"
  with_hostile_names run_expanded "$project" "$project_expanded"
  tail -n "$names_total" "$received" | cmp -s - "$expected" && [ "$(ls -A "$project")" = scripts ]
}
if command -v bash >/dev/null 2>&1; then
  check "FilesAfterAndInABashScript_DeliversEveryName: bash reads the escaped names after the activation" \
    delivers_in_project "bash -c 'source scripts/activate && dotnet format App.sln --verify-no-changes --no-restore --include {files}'"
else
  echo "  skip FilesAfterAndInABashScript_DeliversEveryName: bash is not installed"
fi
check "FilesAsACommand_IsRefused: the first name would run" refuses 'true; {files}'
check "FilesAfterATab_DeliversEveryName: a tab ends the word before it" delivers "record$tab{files}"
check "FilesBeforeATab_DeliversEveryName: a tab ends the word after it" delivers "record {files}$tab"
check "ScriptShellSeparatedByTabs_DeliversEveryName: tabs separate sh, -c and the script" \
  delivers "sh$tab-c$tab'record$tab{files}'"
check "BlanksBeforeTheScriptShell_DeliversEveryName: a run of blanks before sh still starts the command" \
  delivers "$space$tab${space}sh -c 'record {files}'"
check "BlanksAfterASeparatorBeforeTheScriptShell_DeliversEveryName: a run of blanks after ; still starts the command" \
  delivers "true;$tab$space${space}sh -c 'record {files}'"
check "BlanksAfterFiles_DeliversEveryName: a run of blanks ends the word {files}" delivers "record {files}$space$tab$space"
check "BlanksAfterFilesAndTheScript_DeliversEveryName: blank runs inside and after the script end the words" \
  delivers "sh -c 'record {files}$tab$space'$space$tab"
check "BlanksAfterTheScriptsOpeningQuote_DeliversEveryName: the script may start with a run of blanks" \
  delivers "sh -c '$space$tab${space}record {files}'"
check "CombinedShellOptions_IsRefused: only a -c that is a word of its own marks the script" refuses "sh -ec 'record {files}'"
check "ScriptJoinedToTheCOption_IsRefused: -c joined to the script is not a word of its own" refuses "sh -c'record {files}'"
check "COptionJoinedToOtherText_IsRefused: x-c is not the option -c" refuses "sh x-c 'record {files}'"
check "ShellNameJoinedToOtherText_IsRefused: shx is not sh" refuses "shx -c 'record {files}'"
check "ScriptShellAfterAnEscapedSemicolon_IsRefused: an escaped ; does not start a command" \
  refuses "record x\\; sh -c 'record {files}'"
check "FilesOnTheSecondLine_DeliversEveryName: a multi-line command is read line by line" \
  delivers "true${newline}record {files}"
check "FilesOnTheSecondLineOfAScript_DeliversEveryName: a multi-line script is read line by line" \
  delivers "sh -c 'true${newline}record {files}'"
check "FilesAfterANewline_IsRefused: the first name would run" refuses "record$newline{files}"
check "ScriptAfterANewline_IsRefused: the quoted text is not the script of sh -c" refuses "sh -c$newline'record {files}'"
check "FilesAfterACommandSubstitution_IsRefused: the scanner does not follow its quoting" refuses 'record $(echo "x") y {files}'
check "FilesInACommandSubstitutionInDoubleQuotes_IsRefused: a quote inside it does not close the outer one" \
  refuses 'record "$(echo " x {files} ")"'
check "FilesAfterAComment_IsRefused: a commented-out {files} would hand the command no name" refuses 'record # x {files}'
check "QuoteLeftOpen_IsRefused: the command cannot be read" refuses "record {files} 'x"
refusal_names_the_accepted_forms() {
  refusal="$(files_placeholder_expanded 'true; {files}' 2>&1 >/dev/null)"
  for accepted_form in 'word of its own' 'sh -c or bash -c' '"$@"' 'last word'; do
    case "$refusal" in *"$accepted_form"*) ;; *) return 1 ;; esac
  done
}
check "RefusedPlacement_NamesTheAcceptedForms: the message says where {files} may go and how to pass names elsewhere" \
  refusal_names_the_accepted_forms
check "FilesBeforeARedirection_DeliversEveryName: a > ends the word {files}" delivers "record {files}>/dev/null"
check "FilesBeforeAClosingParenthesis_DeliversEveryName: a ) ends the word {files}" delivers "(record {files})"
exit "$((fails > 0))"
