#!/bin/sh
# Tests the {files} placeholder helper against a real sh and bash. It generates configured commands
# over the outer quoting (none, or the single- or double-quoted script of a sh -c or a bash -c), the
# quoting {files} sits in inside it (none, single, double), an escape or quote before {files} or
# inside those quotes and text joined after it, expands each with hostile file names and runs the
# result as the hooks and verify do. Every command must be refused, or deliver every name intact as
# one word and run nothing. Run from anywhere. Exit 1 on any failure.
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

script_text() {
  case "$1" in
    single) script_quote="'" ;; double) script_quote='"' ;; *) script_quote="" ;;
  esac
  case "$2" in
    inside) printf 'record %s %s%s {files}%s' "$3" "$script_quote" "$4" "$script_quote" ;;
    after) printf 'record %s %s%s%s {files}' "$3" "$script_quote" "$4" "$script_quote" ;;
    joined) printf 'record %s %s%s%s{files}' "$3" "$script_quote" "$4" "$script_quote" ;;
    followed) printf 'record %s %s%s {files}x%s' "$3" "$script_quote" "$4" "$script_quote" ;;
  esac
}

configured_command() {
  case "$1" in
    *-single) printf "%s -c '%s'" "${1%-*}" "$2" ;;
    *-double) printf '%s -c "%s"' "${1%-*}" "$2" ;;
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
  fragment_outer="$1"; fragment_inner="$2"; fragment_placement="$3"
  fragments | while IFS= read -r fragment; do
    configured_command "$fragment_outer" "$(script_text "$fragment_inner" "$fragment_placement" "$fragment" "")"; echo
    [ "$fragment_inner" = none ] || [ -z "$fragment" ] && continue
    configured_command "$fragment_outer" "$(script_text "$fragment_inner" "$fragment_placement" "" "$fragment")"; echo
  done
}

placement_commands() {
  placement_outer="$1"; placement_inner="$2"
  for placement in after inside joined followed; do
    [ "$placement_inner:$placement" = none:inside ] && continue
    fragment_commands "$placement_outer" "$placement_inner" "$placement"
  done
}

inner_quoting_commands() {
  for inner_quoting in none single double; do placement_commands "$1" "$inner_quoting"; done
}

generated_commands() {
  for generated_outer in $outer_quotings; do inner_quoting_commands "$generated_outer"; done
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

: > "$broken"; generated_total=0; delivered_total=0
while IFS= read -r generated; do
  generated_total=$((generated_total + 1))
  case "$(outcome "$generated")" in
    broken) printf '%s\n' "$generated" >> "$broken" ;;
    intact) delivered_total=$((delivered_total + 1)) ;;
  esac
done <<EOF_COMMANDS
$(generated_commands)
EOF_COMMANDS
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
check "FilesAfterACommandSubstitution_IsRefused: the scanner does not follow its quoting" refuses 'record $(echo "x") y {files}'
check "FilesInACommandSubstitutionInDoubleQuotes_IsRefused: a quote inside it does not close the outer one" \
  refuses 'record "$(echo " x {files} ")"'
check "FilesAfterAComment_IsRefused: a commented-out {files} would hand the command no name" refuses 'record # x {files}'
check "QuoteLeftOpen_IsRefused: the command cannot be read" refuses "record {files} 'x"
exit "$((fails > 0))"
