#!/bin/sh
# Tests the {files} placeholder helper against a real sh and bash. It generates configured commands
# over the outer quoting (none, or the single- or double-quoted script of a sh -c or a bash -c), the
# quoting {files} sits in inside it (none, single, double) and an escape or quote before {files} or
# inside those quotes, expands each with hostile file names and runs the result as the hooks and
# verify do. Every command must be refused, or deliver every name intact as one word and run
# nothing. Run from anywhere. Exit 1 on any failure.
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

generated_commands() {
  for outer in $outer_quotings; do
    for inner in none single double; do
      for placement in after inside joined; do
        [ "$inner:$placement" = none:inside ] && continue
        fragments | while IFS= read -r fragment; do
          configured_command "$outer" "$(script_text "$inner" "$placement" "$fragment" "")"; echo
          [ "$inner" = none ] || [ -z "$fragment" ] && continue
          configured_command "$outer" "$(script_text "$inner" "$placement" "" "$fragment")"; echo
        done
      done
    done
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
check "FilesJoinedToTheScriptAfterItsQuote_IsRefused: the first name would be script text" refuses "sh -c 'record '{files}"
check "FilesInNestedQuotes_IsRefused: two shells would read the names" refuses "sh -c 'sh -c \"record {files}\"'"
check "FilesAfterADotnetSolution_DeliversEveryName: the names follow the solution's arguments" \
  delivers 'dotnet format style X.sln --include {files}'
check "FilesAfterAnNpxCommand_DeliversEveryName: the names follow the tool's arguments" delivers 'npx prettier --check {files}'
check "FilesInAForLoop_DeliversEveryName: the loop reads each name as one word" \
  delivers 'for f in {files}; do record "$f" || exit 1; done'
check "FilesInAForLoopOfSyntaxChecks_IsAccepted: the loop list becomes the arguments" \
  [ "$(files_placeholder_expanded 'for f in {files}; do sh -n "$f" || exit 1; done')" = 'for f in "$@"; do sh -n "$f" || exit 1; done' ]
check "FilesInAZshScript_IsRefused: only sh and bash read the script by the scanned rules" refuses "zsh -c 'record {files}'"

project="$work/project"; mkdir -p "$project/scripts"; echo 'activated=yes' > "$project/scripts/activate"
delivers_in_project() {
  project_expanded="$(files_placeholder_expanded "$1" 2>/dev/null)" || return 1
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
check "FilesAfterACommandSubstitution_IsRefused: the scanner does not follow its quoting" refuses 'record $(echo "x") {files}'
check "FilesAfterAComment_IsRefused: quotes in a comment are not quotes" refuses "record # it's {files}"
check "QuoteLeftOpen_IsRefused: the command cannot be read" refuses "record {files} 'x"
exit "$((fails > 0))"
