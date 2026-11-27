#!/bin/sh
# config-migration.sh: init brings an existing .standards/config.json to the plugin's migration
# steps, on a copy of the plugin in throwaway repos: comments.doc_inside written where a language
# has doc comments and no such key, left alone where it is an empty list or the language has no
# comments, the report's change lines, the backup named after the version found, the version
# label, a config with nothing to migrate left byte for byte, --check as drift that changes
# nothing, a second run, git status in a project that commits .standards/, the file's indent and
# non-ASCII text, and the session-start hook printing the report once. Takes no argument. Exit 0
# when every check passes, 1 on any failure. tools/test.sh runs it.
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
check() { check_name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$check_name"; else fail "$check_name"; fi; }

plugin_copy="$work/plugin"; cp -R "$hooks/.." "$plugin_copy"; rm -rf "$plugin_copy/evals/results"
init="$plugin_copy/skills/init/scripts/init.sh"; start="$plugin_copy/hooks/session-start.sh"
copy_version="$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1]))["version"])' "$plugin_copy/.claude-plugin/plugin.json")"
default_doc_inside="$(python3 -I -c 'import json, sys
steps = json.load(open(sys.argv[1]))["steps"]
print(json.dumps(next(step["value"] for step in steps if step["name"] == "doc-inside-default")))' "$plugin_copy/skills/init/migrations.json")"
old_label=1.4.1
change_fields=4
written_key=languages.0.comments.doc_inside
migrations=.standards/migrations

new_project() {
  # new_project <name>: an empty git repository at $work/<name>, entered.
  mkdir -p "$work/$1" && cd "$work/$1" && git init -q -b main && git config user.email t@t && git config user.name t
}
write_config() {
  # write_config: a config at the old label with a C# language that has doc comments and no
  # doc_inside, a Go one whose doc_inside is an empty list and a shell one with no comments.
  mkdir -p .standards && cat > .standards/config.json <<JSON
{
  "version": "$old_label",
  "languages": [
    { "name": "csharp", "extensions": [".cs"], "format": [], "comments": { "line": "//", "doc": "///", "public": "public" } },
    { "name": "go", "extensions": [".go"], "format": [], "comments": { "line": "//", "doc": "//", "doc_inside": [] } },
    { "name": "sh", "extensions": [".sh"], "format": [] }
  ],
  "build": "true",
  "test": "true"
}
JSON
}
config_value() {
  # config_value <dotted path>: the JSON of the config's value there, list indexes as numbers, or "absent".
  python3 -I -c 'import json, sys
node = json.load(open(".standards/config.json"))
for part in sys.argv[1].split("."):
    found = isinstance(node, list) and part.isdigit() and int(part) < len(node)
    found = found or (isinstance(node, dict) and part in node)
    if not found:
        print("absent"); sys.exit()
    node = node[int(part)] if isinstance(node, list) else node[part]
print(json.dumps(node))' "$1"
}
value_is() { [ "$(config_value "$1")" = "$2" ]; }
# change_field_count <new key>: how many tab-split fields the report line naming the new key has.
change_field_count() { awk -F'\t' -v key="$1" 'NF > 1 && $2 == key { print NF }' "$migrations/report.txt"; }
# tree_digest: a checksum line per file of the project outside .git, sorted.
tree_digest() { find . -path ./.git -prune -o -type f -exec cksum {} + | sort; }
same_tree() { tree_digest | cmp -s "$1" -; }
installed_with_doc_inside_removed() {
  # installed_with_doc_inside_removed: installs on the current config, then takes the C# doc_inside
  # out again, as in a project whose config predates the key.
  "$init" > /dev/null 2>&1
  python3 -I -c 'import json
path = ".standards/config.json"
config = json.load(open(path))
del config["languages"][0]["comments"]["doc_inside"]
config["version"] = "'"$old_label"'"
open(path, "w").write(json.dumps(config, indent=2) + "\n")'
}

echo "init: a config whose C# language has no doc_inside"
new_project migrated
write_config
cp .standards/config.json "$work/migrated.before"
"$init" > "$work/migrated.init.out" 2>&1
check "Init_LanguageWithDocAndNoDocInside_WritesTheDefault" value_is "$written_key" "$default_doc_inside"
check "Init_DocInsideEmptyList_LeavesItAlone" value_is languages.1.comments.doc_inside "[]"
check "Init_LanguageWithoutComments_GetsNoKey" value_is languages.2.comments absent
check "Init_DocInsideWritten_ReportLineHasFourTabSeparatedFields" [ "$(change_field_count "$written_key")" = "$change_fields" ]
check "Init_DocInsideWritten_BackupNamedAfterTheVersionFound" cmp -s "$work/migrated.before" "$migrations/config.json.$old_label.bak"
check "Init_DocInsideWritten_VersionBecomesTheManifestVersion" value_is version "\"$copy_version\""
tree_digest > "$work/migrated.first"
"$init" > "$work/migrated.second.out" 2>&1
check "Init_RunTwice_SecondRunChangesNothing" same_tree "$work/migrated.first"

echo "session start after a migrating init"
first_start="$(echo '{}' | "$start" 2>&1)"
second_start="$(echo '{}' | "$start" 2>&1)"
check "SessionStart_AfterAMigratingInit_PrintsTheChange" sh -c 'printf "%s" "$1" | grep -qF -- "$2"' _ "$first_start" "$written_key"
check "SessionStart_SecondStart_PrintsNothing" [ -z "$second_start" ]

echo "init: a config with nothing to migrate"
new_project current
write_config
installed_with_doc_inside_removed
"$init" > /dev/null 2>&1
cp .standards/config.json "$work/current.before"
"$init" > "$work/current.init.out" 2>&1
check "Init_NothingToMigrate_ConfigBytesUnchanged" cmp -s "$work/current.before" .standards/config.json

echo "init --check: a step is pending"
new_project pending
write_config
installed_with_doc_inside_removed
tree_digest > "$work/pending.before"
"$init" --check > "$work/pending.check.out" 2>&1
check "InitCheck_PendingStep_NamesItAsDrift" grep -qF -- "drift: .standards/config.json: pending migration: -	$written_key" "$work/pending.check.out"
check "InitCheck_PendingStep_ChangesNothing" same_tree "$work/pending.before"

echo "init: a project that commits .standards/"
new_project committed
write_config
installed_with_doc_inside_removed
git add -A && git commit -qm "chore: install the standards [config]"
"$init" > "$work/committed.init.out" 2>&1
check "Init_CommittedStandardsFolder_IsMigrated" value_is "$written_key" "$default_doc_inside"
check "Init_CommittedStandardsFolder_GitStatusShowsOnlyTheConfig" [ "$(git status --porcelain)" = " M .standards/config.json" ]

echo "init: a config indented by four spaces, with non-ASCII text"
new_project layout
mkdir -p .standards && cat > .standards/config.json <<JSON
{
    "version": "$old_label",
    "_readme": "Réglages du projet",
    "languages": [
        {
            "name": "csharp",
            "extensions": [".cs"],
            "format": [],
            "comments": {
                "doc": "///"
            }
        }
    ],
    "build": "true",
    "test": "true"
}
JSON
"$init" > "$work/layout.init.out" 2>&1
check "Init_FourSpaceIndentAndUnicode_IsMigrated" value_is "$written_key" "$default_doc_inside"
check "Init_FourSpaceIndent_KeptAsWritten" python3 -I -c 'import json, sys
text = open(".standards/config.json", encoding="utf-8").read()
sys.exit(text != json.dumps(json.loads(text), indent=4, ensure_ascii=False) + "\n")'
check "Init_UnicodeText_KeptAsWritten" grep -qF -- '"_readme": "Réglages du projet"' .standards/config.json

[ "$fails" -eq 0 ] && echo "config-migration: ok" || { echo "config-migration: $fails failed"; exit 1; }
