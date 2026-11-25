#!/bin/sh
set -u
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
. "$root/tools/lib/sandbox.sh"; sandbox_enter "$work" "$root/tools"
trap 'sandbox_close $?' EXIT
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }

echo "lint holds ShellCheck and Ruff to the baseline"
python="$(command -v python3)"; linted="$work/linted"; linted_template="$work/linted-template"
mkdir -p "$linted_template/plugins/demo" "$linted_template/tools"; git init -q "$linted_template"
cp "$root/ruff.toml" "$root/.shellcheckrc" "$linted_template/"
printf '#!/bin/sh\nset -u\nprintf "%%s\\n" "$1"\n' > "$linted_template/plugins/demo/clean.sh"
printf 'import os\n\nprint(os.name)\n' > "$linted_template/plugins/demo/clean.py"
"$python" -I "$root/tools/lib/lint_baseline.py" update "$linted_template" >/dev/null
fresh_linted() { rm -rf "$linted"; cp -R "$linted_template" "$linted"; }
baseline_check() { env -u CI "$@" "$python" -I "$root/tools/lib/lint_baseline.py" check "$linted" 2>&1; }
unquoted_substitution() { printf 'echo $(date)\n' >> "$linted/plugins/demo/clean.sh"; }
rule_code_pattern='SC[0-9]{4}|[EFIBS][0-9]{3,4}|SIM[0-9]{3}'
fails_naming() { [ "$1" -eq 1 ] && printf '%s' "$2" | grep -qF -- "$3" && printf '%s' "$2" | grep -qF -- "$4"; }
passes_without_finding() { [ "$1" -eq 0 ] && ! printf '%s' "$2" | grep -Eqw "$rule_code_pattern"; }
fresh_linted
out="$(baseline_check)"; code=$?
check "CleanTree_Passes: exit 0 and no rule named, because the baseline of a clean tree is empty" passes_without_finding "$code" "$out"
unquoted_substitution
out="$(baseline_check)"; code=$?
check "NewShellcheckFinding_FailsAndNamesFileAndRule: exit 1 and the file and rule of the unquoted substitution, because the baseline records none" \
  fails_naming "$code" "$out" SC2046 plugins/demo/clean.sh
fresh_linted
printf 'import sys\n' >> "$linted/plugins/demo/clean.py"
out="$(baseline_check)"; code=$?
check "NewRuffFinding_FailsAndNamesFileAndRule: exit 1 and the file and rule of the unused import, because the baseline records none" \
  fails_naming "$code" "$out" F401 plugins/demo/clean.py
fresh_linted
unquoted_substitution
"$python" -I "$root/tools/lib/lint_baseline.py" update "$linted" >/dev/null
printf '#!/bin/sh\n\n\nset -u\nprintf "%%s\\n" "$1"\necho $(date)\n' > "$linted/plugins/demo/clean.sh"
out="$(baseline_check)"; code=$?
check "RecordedFindingOnAnotherLine_Passes: exit 0 and no rule named, because the baseline counts a rule per file and not its line" passes_without_finding "$code" "$out"
unquoted_substitution
out="$(baseline_check)"; code=$?
check "AnotherFindingOfARecordedRule_Fails: exit 1 and the file and rule named, because a count above the baseline is new" \
  fails_naming "$code" "$out" SC2046 plugins/demo/clean.sh
fresh_linted
unquoted_substitution
"$python" -I "$root/tools/lib/lint_baseline.py" update "$linted" >/dev/null
printf '#!/bin/sh\nset -u\nprintf "%%s\\n" "$1"\n' > "$linted/plugins/demo/clean.sh"
out="$(baseline_check)"; code=$?
check "FixedFinding_Passes: exit 0 and no rule named as new, because fixing a finding must not fail lint" passes_without_finding "$code" "$out"
check "FixedFinding_PointsToUpdate: the output names the update command, because the baseline can then be lowered" \
  sh -c 'printf "%s" "$1" | grep -qw update' sh "$out"
path_with() {
  name="$1"; shift; rm -rf "$work/path-$name"; mkdir -p "$work/path-$name"
  for tool in git "$@"; do ln -s "$(command -v "$tool")" "$work/path-$name/$tool"; done
}
path_with no-linters
path_with only-ruff ruff
path_with only-shellcheck shellcheck
fresh_linted
out="$(baseline_check "PATH=$work/path-only-ruff")"; code=$?
check "MissingShellcheckLocally_NamesHowToInstallIt: the output names shellcheck and its install command, because a developer must know what to install" \
  sh -c 'printf "%s" "$1" | grep -q "brew install shellcheck"' sh "$out"
out="$(baseline_check "PATH=$work/path-only-shellcheck")"; code=$?
check "MissingRuffLocally_NamesHowToInstallIt: the output names ruff and the file that pins it, because a developer must know what to install" \
  sh -c 'printf "%s" "$1" | grep -q "pip install -r tools/requirements-lint.txt"' sh "$out"
out="$(baseline_check "PATH=$work/path-no-linters")"; code=$?
check "MissingToolsLocally_Pass: exit 0, because a developer without the tools is not blocked" [ "$code" -eq 0 ]
out="$(baseline_check "PATH=$work/path-only-ruff" CI=1)"; code=$?
check "MissingShellcheckInCi_Fails: exit 1 and shellcheck named, because CI must run the checks it promises" \
  sh -c '[ "$1" -eq 1 ] && printf "%s" "$2" | grep -q shellcheck' sh "$code" "$out"
out="$(baseline_check "PATH=$work/path-only-shellcheck" CI=1)"; code=$?
check "MissingRuffInCi_Fails: exit 1 and ruff named, because CI must run the checks it promises" \
  sh -c '[ "$1" -eq 1 ] && printf "%s" "$2" | grep -q ruff' sh "$code" "$out"
rewrite_python() { printf '%b' "$1" > "$linted/plugins/demo/clean.py"; }
python_finding_named() {
  fresh_linted; rewrite_python "$3"; out="$(baseline_check)"; code=$?
  check "$1: exit 1 and $2 named for the file, because the chosen rule family must fail a new finding" \
    fails_naming "$code" "$out" "$2" plugins/demo/clean.py
}
python_finding_named "NewPycodestyleErrorFinding_Fails" E711 'import os\n\nprint(os.name == None)\n'
python_finding_named "NewImportOrderFinding_Fails" I001 'import sys\nimport os\n\nprint(os.name, sys.argv)\n'
python_finding_named "NewBugbearFinding_Fails" B006 'import os\n\n\ndef collect(items=[]):\n    return items\n\n\nprint(os.name)\n'
python_finding_named "NewBanditFinding_Fails" S605 'import os\n\nos.system("true")\n'
python_finding_named "NewFileOpenedWithoutWithFinding_Fails" SIM115 'import os\n\nhandle = open("data")\nprint(handle, os.name)\n'
python_finding_passes() {
  fresh_linted; rewrite_python "$3"; out="$(baseline_check)"; code=$?
  check "$1: exit 0 and no rule named, because $2 are not turned on yet" passes_without_finding "$code" "$out"
}
python_finding_passes "UnannotatedFunction_Passes" "annotation rules" 'import os\n\n\ndef describe(name):\n    return os.name + name\n\n\nprint(describe("x"))\n'
line_longer_than_the_limit=120
python_finding_passes "LongLine_Passes" "formatting checks" "import os\n\nprint(os.name, \"$(printf "%0${line_longer_than_the_limit}d" 0)\")\n"
python_finding_passes "TrailingWhitespace_Passes" "formatting checks" 'import os\n\nprint(os.name) \n'
fresh_linted
printf '#!/bin/sh\necho $1\n' >> "$linted/plugins/demo/clean.sh"
out="$(baseline_check)"; code=$?
check "UnquotedVariable_Passes: exit 0 and no rule named, because ShellCheck runs at warning severity and above" passes_without_finding "$code" "$out"
fresh_linted
printf '[[ -n "$1" ]]\n' > "$linted/plugins/demo/no-shebang.sh"
out="$(baseline_check)"; code=$?
check "BashismInFileWithoutShebang_Fails: exit 1 and SC3010 named, because the config makes ShellCheck read it as POSIX sh" \
  fails_naming "$code" "$out" SC3010 plugins/demo/no-shebang.sh
fresh_linted
mkdir -p "$linted/plugins/demo/hooks/git"; printf '#!/bin/sh\necho $(date)\n' > "$linted/plugins/demo/hooks/git/pre-commit"
out="$(baseline_check)"; code=$?
check "NewFindingInGitHookWithoutExtension_Fails: exit 1 and the hook named, because a hook is shell without a .sh name" \
  fails_naming "$code" "$out" SC2046 plugins/demo/hooks/git/pre-commit
fresh_linted
unquoted_substitution
"$python" -I "$root/tools/lib/lint_baseline.py" update "$linted" >/dev/null
printf '#!/bin/sh\nset -u\nprintf "%%s\\n" "$1"\n' > "$linted/plugins/demo/clean.sh"
"$python" -I "$root/tools/lib/lint_baseline.py" update "$linted" >/dev/null
unquoted_substitution
out="$(baseline_check)"; code=$?
check "FindingReturningAfterUpdate_Fails: exit 1 and the file named, because update lowers the baseline to what was fixed" \
  fails_naming "$code" "$out" SC2046 plugins/demo/clean.sh
fresh_linted
out="$(cd "$work" && env -u CI "$python" -I "$root/tools/lib/lint_baseline.py" check "$(basename "$linted")" 2>&1)"; code=$?
check "RootRelativeToTheWorkingFolder_Passes: exit 0 and no rule named, because a relative ROOT must still lead Ruff to the root's configuration" passes_without_finding "$code" "$out"
fresh_linted
out="$("$python" -I "$root/tools/lib/lint_baseline.py" check "$work/no-such-folder" 2>&1)"; code=$?
check "CheckOnFolderWithoutConfig_Fails: a nonzero exit, because a mistyped root must not pass in silence" [ "$code" -ne 0 ]
printf 'plugins/demo/clean.sh\tSC2046\tmany\n' > "$linted/tools/lint-baseline/shellcheck.tsv"
out="$(baseline_check)"; code=$?
check "MalformedBaselineLine_Fails: exit 1 and the baseline file named, because a baseline that cannot be read must not pass" \
  fails_naming "$code" "$out" shellcheck.tsv shellcheck
baseline_lines_hold_file_rule_and_count='NF != 3 || $1 ~ /:/ || $2 !~ /^[A-Za-z]+[0-9]+$/ || $3 !~ /^[0-9]+$/ { bad = 1 } END { exit bad }'
fresh_linted
unquoted_substitution
printf 'import sys\n' >> "$linted/plugins/demo/clean.py"
"$python" -I "$root/tools/lib/lint_baseline.py" update "$linted" >/dev/null
check "UpdatedBaselineFiles_HoldFileRuleAndCountOnly: every line is a file, a rule code and a count, because a line number would break on any shift" \
  sh -c '[ -s "$2/shellcheck.tsv" ] && [ -s "$2/ruff.tsv" ] && awk -F "\t" "$1" "$2"/shellcheck.tsv "$2"/ruff.tsv' sh "$baseline_lines_hold_file_rule_and_count" "$linted/tools/lint-baseline"
check "CommittedBaselineFiles_HoldFileRuleAndCountOnly: the real baselines have no line numbers, because they must survive line shifts" \
  sh -c '[ -s "$2/shellcheck.tsv" ] && awk -F "\t" "$1" "$2"/shellcheck.tsv "$2"/ruff.tsv' sh "$baseline_lines_hold_file_rule_and_count" "$root/tools/lint-baseline"
fresh_linted
unquoted_substitution
printf 'greeting=hello\n' > "$linted/plugins/demo/settings.sh"
printf '#!/bin/sh\n# shellcheck source=plugins/demo/settings.sh\n. "$(dirname "$0")/settings.sh"\nprintf "%%s\\n" "$greeting"\n' > "$linted/plugins/demo/greet.sh"
one_chunk=1; three_chunks=3
"$python" -I "$root/tools/lib/lint_baseline.py" update "$linted" --shellcheck-chunks "$one_chunk" >/dev/null
cp "$linted/tools/lint-baseline/shellcheck.tsv" "$work/one-chunk.tsv"
"$python" -I "$root/tools/lib/lint_baseline.py" update "$linted" --shellcheck-chunks "$three_chunks" >/dev/null
check "ShellcheckBaselineFromThreeChunks_EqualsOneChunk: the same baseline file, because ShellCheck reports per file and follows a sourced file outside its own chunk" \
  sh -c '[ -s "$1" ] && cmp -s "$1" "$2"' sh "$work/one-chunk.tsv" "$linted/tools/lint-baseline/shellcheck.tsv"
fresh_linted
mkdir -p "$linted/tools/lib"; cp "$root/tools/lint.sh" "$linted/tools/"; cp "$root"/tools/lib/lint_*.py "$linted/tools/lib/"
"$python" -I "$root/tools/lib/lint_baseline.py" update "$linted" >/dev/null
printf '#!/bin/sh\necho $(date)\n' > "$linted/plugins/demo/new-finding.sh"
printf 'import shutil\n' > "$linted/plugins/demo/new_finding.py"
out="$("$linted/tools/lint.sh" 2>/dev/null)"; code=$?
check "LintWithNewShellcheckFinding_FailsAndNamesFileAndRule: tools/lint.sh exits 1 naming the new script and SC2046, because lint runs the baseline check" \
  fails_naming "$code" "$out" SC2046 plugins/demo/new-finding.sh
check "LintWithNewRuffFinding_FailsAndNamesFileAndRule: tools/lint.sh exits 1 naming the new module and F401, because lint runs the baseline check" \
  fails_naming "$code" "$out" F401 plugins/demo/new_finding.py
real_ruff="$(command -v ruff)"; mkdir -p "$work/other-ruff"; unpinned_ruff_version=0.0.1
printf '#!/bin/sh\n[ "$1" = "--version" ] && { echo "ruff %s"; exit 0; }\nexec "%s" "$@"\n' "$unpinned_ruff_version" "$real_ruff" > "$work/other-ruff/ruff"; chmod +x "$work/other-ruff/ruff"
fresh_linted
cp "$root/tools/requirements-lint.txt" "$linted/tools/"
out="$(baseline_check "PATH=$work/other-ruff:$PATH")"; code=$?
check "RuffAtAnotherVersionLocally_NotesAndPasses: exit 0 and the installed version named, because a developer's version is a note and not a failure" \
  sh -c '[ "$1" -eq 0 ] && printf "%s" "$2" | grep -qF "$3"' sh "$code" "$out" "$unpinned_ruff_version"
out="$(baseline_check "PATH=$work/other-ruff:$PATH" CI=1)"; code=$?
check "RuffAtAnotherVersionInCi_Fails: exit 1 and the installed version named, because CI must run the pinned version the baseline came from" \
  sh -c '[ "$1" -eq 1 ] && printf "%s" "$2" | grep -qF "$3"' sh "$code" "$out" "$unpinned_ruff_version"
writes_bytecode() {
  writes_probe="$(mktemp -d "$work/probe.XXXXXX")"; printf 'probed = 1\n' > "$writes_probe/probe.py"
  "$1" -I -c 'import sys; sys.path.append(sys.argv[1]); import probe' "$writes_probe" 2>/dev/null || true
  if [ -d "$writes_probe/__pycache__" ]; then rm -r "$writes_probe"; return 0; fi
  rm -r "$writes_probe"; return 1
}
bytecode_writer=""
for candidate in "$python" /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  if [ -x "$candidate" ] && writes_bytecode "$candidate"; then bytecode_writer="$candidate"; break; fi
done
if [ -n "$bytecode_writer" ]; then
  fresh_linted
  mkdir -p "$linted/tools/lib" "$work/bytecode-writer"; cp "$root"/tools/lib/lint_*.py "$linted/tools/lib/"
  ln -s "$bytecode_writer" "$work/bytecode-writer/python3"
  untracked_before="$(git -C "$linted" status --porcelain --untracked-files=all)"
  (PATH="$work/bytecode-writer:$PATH" && python3 -I "$linted/tools/lib/lint_baseline.py" update >/dev/null 2>&1); code=$?
  check "UpdateUnderAPythonThatWritesBytecode_Passes: exit 0, because $bytecode_writer runs the tool like any python3" [ "$code" -eq 0 ]
  check "UpdateUnderAPythonThatWritesBytecode_LeavesNoUntrackedFile: git lists the same files as before, because the tool never writes compiled modules into the project it lints" \
    sh -c '[ "$(git -C "$1" status --porcelain --untracked-files=all)" = "$2" ]' sh "$linted" "$untracked_before"
  rm -r "$work/bytecode-writer"
else
  echo "skip UpdateUnderAPythonThatWritesBytecode: no python3 here writes bytecode under -I"
fi

[ "$fails" -eq 0 ] && echo "lint baseline: ok"
exit $(( fails > 0 ))
