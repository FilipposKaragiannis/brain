#!/bin/sh
# appendices.sh: the rule generator renders one file per language appendix, and init installs an
# appendix only for a configured language, scoped to that language's files. Runs tools/generate.sh
# on a copy of the checkout, never on the checkout, and installs on throwaway projects from a copy
# of the plugin. Exit 0 when every check passes, 1 on any failure. tools/test.sh runs it.
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
PYTHONDONTWRITEBYTECODE=1; export PYTHONDONTWRITEBYTECODE
repository_root="$(cd "$hooks/../../.." && pwd)"
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
snapshot() {
  # snapshot <folder>: a checksum line per file under <folder>, sorted.
  (cd "$1" && find . -type f -exec cksum {} + | sort)
}
paths_of() {
  # paths_of <Claude rule file>: the globs its front matter loads it for, one per line.
  awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside && /^  - / { sub(/^  - "/, ""); sub(/"$/, ""); print }' "$1"
}
generator_stops_cleanly() {
  # generator_stops_cleanly <stderr file> <reason>: the last generate exited 1 naming the reason, with no traceback, and wrote no rule file.
  [ "$generate_status" -eq 1 ] && grep -qF -- "$2" "$1" && ! grep -q Traceback "$1" \
    && diff -r "$copy/plugins/standards/rules" "$repository_root/plugins/standards/rules"
}

echo "generator"
copy="$work/checkout"; mkdir -p "$copy"
tar -C "$repository_root" --exclude=./.git -cf - . | tar -C "$copy" -xf -
standards_source="$copy/docs/coding-standards.md"
rules_out="$copy/plugins/standards/rules"
snapshot "$copy" > "$work/generate.before"
sh "$copy/tools/generate.sh" > "$work/generate.first.out" 2>&1
snapshot "$copy" > "$work/generate.first"
sh "$copy/tools/generate.sh" > "$work/generate.second.out" 2>&1
snapshot "$copy" > "$work/generate.second"
check "GenerateTwice_GivesIdenticalOutput: a second tools/generate.sh run changes no file, so a regenerate is a no-op" \
  cmp -s "$work/generate.first" "$work/generate.second"
check "CheckoutGenerated_IsFresh: tools/generate.sh on the checkout's sources changes no committed file" \
  cmp -s "$work/generate.before" "$work/generate.first"
check "EveryAppendixId_ResolvesToItsFile: each id of an appendix section is indexed as a convention of that appendix's file, and every CS, SH and PY id is among them" \
  python3 -I -c 'import json, re, sys
rules_out, source = sys.argv[1], sys.argv[2]
listed = {entry["language"]: entry["file"] for entry in json.load(open(rules_out + "/appendices.json"))}
expected, language = {}, ""
for line in open(source, encoding="utf-8").read().split("\n"):
    if line.startswith("## "):
        heading = re.match(r"^## Appendix [A-Z]\. (.+)$", line)
        language = heading.group(1).strip() if heading else ""
    rule = re.match(r"^- \*\*([A-Z]+-\d\d)", line)
    if language and rule:
        expected[rule.group(1)] = listed[language]
assert {"CS", "SH", "PY"} <= {rule_id.split("-")[0] for rule_id in expected}, expected
index = json.load(open(rules_out + "/index.json"))
indexed = {rule_id: entry["file"] for rule_id, entry in index.items() if entry["tag"] == "convention"}
assert indexed == expected, (indexed, expected)
for rule_id, file in expected.items():
    assert ("**" + rule_id + "**") in open(rules_out + "/" + file, encoding="utf-8").read(), rule_id' "$rules_out" "$standards_source"
check "Block_FitsSixKilobytes: the compact block stays inside the Codex budget" \
  sh -c '[ "$(wc -c < "$1" | tr -d " ")" -le 6144 ]' _ "$rules_out/block.md"
check "Block_NamesEveryAppendix: the block points at the C#, shell and Python appendix files" \
  sh -c 'tr "\n" " " < "$1" | grep -q "rules/csharp.md.*rules/shell.md.*rules/python.md"' _ "$rules_out/block.md"

printf '\n## Appendix D. TypeScript\n\n- **TS-01** No `any`.\n' >> "$standards_source"
sh "$copy/tools/generate.sh" > "$work/generate.nofiles.out" 2> "$work/generate.nofiles.err"; generate_status=$?
check "AppendixWithoutFilesLine_StopsTheGenerator: an appendix that names no file types has no scope, so generate exits 1 with the reason and writes nothing" \
  generator_stops_cleanly "$work/generate.nofiles.err" "Appendix D. TypeScript has no 'Files:"
python3 -I -c 'import sys
source = open(sys.argv[1], encoding="utf-8").read()
heading = "\n## Appendix A. C#"
rules = "".join("- **X-%02d A rule whose title is long enough to fill the budget of the compact block.** [hard] Text.\n" % n for n in range(60))
open(sys.argv[2], "w", encoding="utf-8").write(source.replace(heading, "\n" + rules + heading, 1))' \
  "$repository_root/docs/coding-standards.md" "$standards_source"
sh "$copy/tools/generate.sh" > "$work/generate.oversize.out" 2> "$work/generate.oversize.err"; generate_status=$?
check "BlockOverSixKilobytes_StopsTheGenerator: a block over its limit makes generate exit 1 with the reason and write nothing" \
  generator_stops_cleanly "$work/generate.oversize.err" "byte limit"
cp "$repository_root/docs/coding-standards.md" "$standards_source"
printf '\n## Appendix D. TypeScript\n\nFiles: `.ts`, `.tsx`.\n\n- **TS-01** No `any`.\n' >> "$standards_source"
sh "$copy/tools/generate.sh" > "$work/generate.fourth.out" 2>&1
check "FourthAppendix_RendersWithNoCodeChange: a new appendix heading in the source yields its own file and extensions" \
  python3 -I -c 'import json, sys
listed = {entry["file"]: entry["extensions"] for entry in json.load(open(sys.argv[1] + "/appendices.json"))}
assert listed.get("typescript.md") == [".ts", ".tsx"], listed
assert json.load(open(sys.argv[1] + "/index.json"))["TS-01"]["file"] == "typescript.md"' "$rules_out"

plugin_copy="$work/plugin"; cp -R "$hooks/.." "$plugin_copy"; rm -rf "$plugin_copy/evals/results"
init="$plugin_copy/skills/init/scripts/init.sh"
new_project() {
  # new_project <folder>: an empty git repository at <folder>, entered.
  mkdir -p "$1" && cd "$1" && git init -q -b main && git config user.email t@t && git config user.name t
}
configure_shell_and_python() {
  # configure_shell_and_python: writes a .standards/config.json for shell and Python in the current project.
  mkdir -p .standards && cat > .standards/config.json <<'JSON'
{
  "version": "0.0.0",
  "languages": [
    { "name": "sh", "extensions": [".sh"], "format": [] },
    { "name": "python", "extensions": [".py"], "format": [] }
  ],
  "build": "true",
  "test": "true"
}
JSON
}
unchanged_on_second_install() {
  # unchanged_on_second_install <log stem>: runs init again in the current project; fails when it changes a file.
  find . -path ./.git -prune -o -type f -exec cksum {} + | sort > "$1.before"
  "$init" > "$1.second.out" 2>&1
  find . -path ./.git -prune -o -type f -exec cksum {} + | sort > "$1.after"
  ! grep -q "^Changed:" "$1.second.out" && cmp -s "$1.before" "$1.after"
}

echo "init: a project configured for C# only"
new_project "$work/csharp"
mkdir -p src/App && printf 'Microsoft Visual Studio Solution File\n' > src/App.sln && printf 'class A {}\n' > src/App/A.cs
"$init" > "$work/csharp.init.out" 2>&1
check "CsharpOnly_InstallsTheCsharpAppendix: the C# appendix lands in .standards/rules and .claude/rules" \
  sh -c '[ -f .standards/rules/csharp.md ] && [ -f .claude/rules/standards-csharp.md ]'
check "CsharpOnly_InstallsNoShellOrPythonAppendix: no shell or Python rules load in a C# project" \
  sh -c '[ ! -e .standards/rules/shell.md ] && [ ! -e .standards/rules/python.md ] && [ ! -e .claude/rules/standards-shell.md ] && [ ! -e .claude/rules/standards-python.md ]'
check "CsharpOnly_ScopesTheCsharpAppendixToCsFiles: the C# rule loads for .cs files alone" \
  [ "$(paths_of .claude/rules/standards-csharp.md)" = "**/*.cs" ]
check "CsharpOnlySecondInstall_ChangesNothing: init run again in the C# project leaves every file as it was" \
  unchanged_on_second_install "$work/csharp"

echo "init: a project configured for shell and Python"
new_project "$work/scripts"
configure_shell_and_python
"$init" > "$work/scripts.init.out" 2>&1
check "ShellAndPython_ScopesTheShellAppendixToShellFiles: the shell rule loads for .sh files alone" \
  [ "$(paths_of .claude/rules/standards-shell.md)" = "**/*.sh" ]
check "ShellAndPython_ScopesThePythonAppendixToPythonFiles: the Python rule loads for .py files alone" \
  [ "$(paths_of .claude/rules/standards-python.md)" = "**/*.py" ]
check "ShellAndPython_InstallsNoCsharpAppendix: a shell read never loads the C# rules" \
  sh -c '[ ! -e .standards/rules/csharp.md ] && [ ! -e .claude/rules/standards-csharp.md ]'
check "ShellAndPython_CommonRulesLoadForBothLanguages: a common section keeps the globs of every configured language" \
  [ "$(paths_of .claude/rules/standards-design.md | tr '\n' ' ')" = "**/*.sh **/*.py " ]
check "ShellAndPythonSecondInstall_ChangesNothing: init run again in the shell and Python project leaves every file as it was" \
  unchanged_on_second_install "$work/scripts"
python3 -I -c 'import json, sys; path = sys.argv[1]; config = json.load(open(path)); config["languages"] = config["languages"][:1]; json.dump(config, open(path, "w"))' .standards/config.json
"$init" > "$work/scripts.dropped.out" 2>&1
check "LanguageDropped_RemovesItsAppendix: init removes the Python rules it wrote once Python leaves the config" \
  sh -c '[ ! -e .standards/rules/python.md ] && [ ! -e .claude/rules/standards-python.md ] && [ -f .claude/rules/standards-shell.md ]'

echo "init: machine scope"
new_project "$work/machine"
configure_shell_and_python
machine_claude_home="$work/claude home"
CLAUDE_CONFIG_DIR="$machine_claude_home" CODEX_HOME="$work/codex" "$init" --scope machine > "$work/machine.init.out" 2>&1
check "MachineScope_ScopesEveryAppendixToItsOwnFiles: every appendix the plugin lists lands in the user rules folder, loaded for its own extensions alone" \
  python3 -I -c 'import json, sys
appendices = json.load(open(sys.argv[1]))
assert appendices, appendices
for entry in appendices:
    lines = open(sys.argv[2] + "/standards-" + entry["file"], encoding="utf-8").read().split("\n")
    paths = [line.strip()[len("- \""):-len("\"")] for line in lines[2:lines.index("---", 1)]]
    assert paths == ["**/*" + extension for extension in entry["extensions"]], (entry, paths)' \
  "$plugin_copy/rules/appendices.json" "$machine_claude_home/rules"

echo "init: the drift hash"
hash_before="$("$init" --source-hash)"
printf -- '- **SH-99** A rule added after the install.\n' >> "$plugin_copy/rules/shell.md"
check "AppendixEdited_ChangesTheSourceHash: the session-start nudge sees a changed appendix" \
  [ "$("$init" --source-hash)" != "$hash_before" ]
hash_before="$("$init" --source-hash)"
printf -- '- **CS-99** A rule added after the install.\n' >> "$plugin_copy/rules/csharp.md"
check "CsharpAppendixEdited_ChangesTheSourceHash: the C# appendix is inside the drift hash too" \
  [ "$("$init" --source-hash)" != "$hash_before" ]
hash_before="$("$init" --source-hash)"
printf '\n' >> "$plugin_copy/rules/appendices.json"
check "AppendixListEdited_ChangesTheSourceHash: the list that scopes each appendix is inside the drift hash" \
  [ "$("$init" --source-hash)" != "$hash_before" ]

[ "$fails" -eq 0 ] && echo "appendices: ok" || { echo "appendices: $fails failed"; exit 1; }
