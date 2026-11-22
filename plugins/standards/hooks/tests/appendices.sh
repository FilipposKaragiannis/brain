#!/bin/sh
# appendices.sh: the rule generator renders one file per language appendix, and init installs an
# appendix only for a configured language, scoped to that language's files. Renders from the
# checkout without writing to it, and installs on throwaway projects from a copy of the plugin.
# Exit 0 when every check passes, 1 on any failure. tools/test.sh runs it.
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
repo="$(cd "$hooks/../../.." && pwd)"
version="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$repo/plugins/standards/plugin.source.json")"
fails=0
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }
check() { name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
render() {
  # render <root> <out folder>: writes what tools/lib/rules.py renders from <root> under <out folder>.
  python3 -B -I - "$repo/tools/lib" "$1" "$2" "$version" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import rules
for path, content in rules.render(sys.argv[2], sys.argv[4]).items():
    target = os.path.join(sys.argv[3], path)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "w", encoding="utf-8") as out:
        out.write(content)
PY
}
paths_of() {
  # paths_of <Claude rule file>: the globs its front matter loads it for, one per line.
  awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside && /^  - / { sub(/^  - "/, ""); sub(/"$/, ""); print }' "$1"
}

echo "generator"
render "$repo" "$work/render-1" && render "$repo" "$work/render-2"
check "RenderTwice_GivesIdenticalOutput: generating twice writes the same files, so a regenerate is a no-op" \
  diff -r "$work/render-1" "$work/render-2"
check "CheckoutRules_AreFresh: the committed rule files are what the generator renders" \
  diff -r "$work/render-1/plugins/standards/rules" "$repo/plugins/standards/rules"
rules_out="$work/render-1/plugins/standards/rules"
check "EveryAppendixId_ResolvesToItsFile: each CS, SH and PY id is indexed as a convention of its own appendix file" \
  python3 -I -c 'import json, sys
index = json.load(open(sys.argv[1]))
expected = {"CS": ("csharp.md", 13), "SH": ("shell.md", 13), "PY": ("python.md", 18)}
for prefix, (file, count) in expected.items():
    ids = [rule_id for rule_id in index if rule_id.startswith(prefix + "-")]
    assert len(ids) == count, (prefix, len(ids))
    for rule_id in ids:
        entry = index[rule_id]
        assert entry["file"] == file and entry["tag"] == "convention", (rule_id, entry)
        assert ("**" + rule_id + "**") in open(sys.argv[2] + "/" + file).read(), rule_id' "$rules_out/index.json" "$rules_out"
check "Block_FitsSixKilobytes: the compact block stays inside the Codex budget" \
  sh -c '[ "$(wc -c < "$1" | tr -d " ")" -le 6144 ]' _ "$rules_out/block.md"
check "Block_NamesEveryAppendix: the block points at the C#, shell and Python appendix files" \
  sh -c 'tr "\n" " " < "$1" | grep -q "rules/csharp.md.*rules/shell.md.*rules/python.md"' _ "$rules_out/block.md"
mkdir -p "$work/fourth/docs"
cp "$repo/docs/coding-standards.md" "$work/fourth/docs/coding-standards.md"
printf '\n## Appendix D. TypeScript\n\nFiles: `.ts`, `.tsx`.\n\n- **TS-01** No `any`.\n' >> "$work/fourth/docs/coding-standards.md"
render "$work/fourth" "$work/fourth/out"
check "FourthAppendix_RendersWithNoCodeChange: a new appendix heading in the source yields its own file and extensions" \
  python3 -I -c 'import json, sys
listed = {entry["file"]: entry["extensions"] for entry in json.load(open(sys.argv[1] + "/appendices.json"))}
assert listed.get("typescript.md") == [".ts", ".tsx"], listed
assert json.load(open(sys.argv[1] + "/index.json"))["TS-01"]["file"] == "typescript.md"' "$work/fourth/out/plugins/standards/rules"
mkdir -p "$work/nofiles/docs" "$work/oversize/docs"
cp "$repo/docs/coding-standards.md" "$work/nofiles/docs/coding-standards.md"
printf '\n## Appendix D. TypeScript\n\n- **TS-01** No `any`.\n' >> "$work/nofiles/docs/coding-standards.md"
if render "$work/nofiles" "$work/nofiles/out" 2>/dev/null; then
  fail "AppendixWithoutFilesLine_StopsTheGenerator: an appendix that names no file types has no scope, so the render must fail"
else
  pass "AppendixWithoutFilesLine_StopsTheGenerator: an appendix that names no file types has no scope, so the render must fail"
fi
python3 -I -c 'import sys
source = open(sys.argv[1]).read()
heading = "\n## Appendix A. C#"
rules = "".join("- **X-%02d A rule whose title is long enough to fill the budget of the compact block.** [hard] Text.\n" % n for n in range(60))
open(sys.argv[2], "w").write(source.replace(heading, "\n" + rules + heading, 1))' \
  "$repo/docs/coding-standards.md" "$work/oversize/docs/coding-standards.md"
if render "$work/oversize" "$work/oversize/out" 2>/dev/null; then
  fail "BlockOverSixKilobytes_StopsTheGenerator: a block over its limit must not be written"
else
  pass "BlockOverSixKilobytes_StopsTheGenerator: a block over its limit must not be written"
fi

plugin_copy="$work/plugin"; cp -R "$hooks/.." "$plugin_copy"; rm -rf "$plugin_copy/evals/results"
init="$plugin_copy/skills/init/scripts/init.sh"
new_project() {
  # new_project <folder>: an empty git repository at <folder>, entered.
  mkdir -p "$1" && cd "$1" && git init -q -b main && git config user.email t@t && git config user.name t
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

echo "init: a project configured for shell and Python"
new_project "$work/scripts"
mkdir -p .standards
cat > .standards/config.json <<'JSON'
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
"$init" > "$work/scripts.init.out" 2>&1
check "ShellAndPython_ScopesTheShellAppendixToShellFiles: the shell rule loads for .sh files alone" \
  [ "$(paths_of .claude/rules/standards-shell.md)" = "**/*.sh" ]
check "ShellAndPython_ScopesThePythonAppendixToPythonFiles: the Python rule loads for .py files alone" \
  [ "$(paths_of .claude/rules/standards-python.md)" = "**/*.py" ]
check "ShellAndPython_InstallsNoCsharpAppendix: a shell read never loads the C# rules" \
  sh -c '[ ! -e .standards/rules/csharp.md ] && [ ! -e .claude/rules/standards-csharp.md ]'
check "ShellAndPython_CommonRulesLoadForBothLanguages: a common section keeps the globs of every configured language" \
  [ "$(paths_of .claude/rules/standards-design.md | tr '\n' ' ')" = "**/*.sh **/*.py " ]
find . -path ./.git -prune -o -type f -exec cksum {} + | sort > "$work/scripts.before"
"$init" > "$work/scripts.second.out" 2>&1
find . -path ./.git -prune -o -type f -exec cksum {} + | sort > "$work/scripts.after"
check "SecondInstall_ChangesNothing: init run again leaves every file as it was" \
  sh -c '! grep -q "^Changed:" "$1" && cmp -s "$2" "$3"' _ "$work/scripts.second.out" "$work/scripts.before" "$work/scripts.after"
python3 -I -c 'import json, sys; path = sys.argv[1]; config = json.load(open(path)); config["languages"] = config["languages"][:1]; json.dump(config, open(path, "w"))' .standards/config.json
"$init" > "$work/scripts.dropped.out" 2>&1
check "LanguageDropped_RemovesItsAppendix: init removes the Python rules it wrote once Python leaves the config" \
  sh -c '[ ! -e .standards/rules/python.md ] && [ ! -e .claude/rules/standards-python.md ] && [ -f .claude/rules/standards-shell.md ]'

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
