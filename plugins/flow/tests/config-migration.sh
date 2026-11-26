#!/bin/sh
# config-migration.sh: init brings an existing .flow/config.yaml to the plugin's migration steps,
# on a copy of the plugin in throwaway repos: the retro.commit removal as cfg reads it, the backup
# named after the label found, the report's change lines, --check as drift that changes nothing, a
# second run, the owner's comments and line endings, a refused file, a taken backup name, git
# status, the migration before the first copy, fixture step lists for add and step order, and the
# label a fresh install writes. Takes no argument. Exit 0 when every check passes, 1 on any failure.
# shellcheck disable=SC2154 # _base_fixture.sh and _init_fixture.sh set plugin, work, here, plugin_copy, init and fails
# shellcheck disable=SC2034 # the check conditions read these names, through eval in _base_fixture.sh's check
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
P="$plugin"
. "$here/_init_fixture.sh"

steps="$plugin_copy/skills/init/migrations.json"
cp "$steps" "$work/shipped-migrations.json"
copy_version="$(json_value version < "$plugin_copy/.claude-plugin/plugin.json")"
drift_exit=1
change_fields=4
config_body='adapters:\n  default: local\nbase: main\npool:\npool_max: 1\nnotify:\n  desktop: false\n'
old_label=1.40.0
# new_project <name> <config text for printf>: a fresh repo in $work/<name> holding that config, the shell in it.
new_project() {
  mkdir -p "$work/$1" && cd "$work/$1" && git init -q -b main && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init || exit 1
  mkdir -p .flow && printf '%b' "$2" > .flow/config.yaml
}
run_init() { FLOW_PLUGIN="$plugin_copy" "$init" "$@"; }
project_cfg() { (. "$plugin_copy/lib/flow.sh"; cfg "$1"); }
project_keys() { (. "$plugin_copy/lib/flow.sh"; yaml_keys .flow/config.yaml "$1"); }
# change_line <old key>: the report line whose first field is the old key.
change_line() { awk -F'\t' -v key="$1" 'NF > 1 && $1 == key' .flow/migrations/report.txt; }
# tree_digest: every file of the project outside .git with its content hash.
tree_digest() { find . -path ./.git -prune -o -type f -print | sort | while IFS= read -r project_file; do printf '%s %s\n' "$(content_hash "$project_file")" "$project_file"; done; }
content_hash() { shasum -a 256 < "$1" | cut -d' ' -f1; }
# line_of <pattern> <file>: the number of the first line holding the fixed text.
line_of() { grep -nF -- "$1" "$2" | head -n 1 | cut -d: -f1; }

echo "retro.commit is removed"
new_project retro "${config_body}retro:\n  commit: false\n"
cp .flow/config.yaml "$work/retro.before"
run_init > "$work/retro.out" 2>&1
check "Init_RetroCommitSet_CfgReadsItEmpty" '[ -z "$(project_cfg retro.commit)" ]'
check "Init_RetroCommitSet_RemovesTheKeyFromItsMap" '! project_keys retro | grep -qx commit'
check "Init_UnlabelledConfig_BackupHoldsTheOldFileAsUnversioned" 'cmp -s "$work/retro.before" .flow/migrations/config.yaml.unversioned.bak'
check "Init_RetroCommitSet_ReportLineHasFourTabSeparatedFields" '[ "$(change_line retro.commit | awk -F"\t" "{ print NF }")" = "$change_fields" ]'
check "Init_RetroCommitSet_ReportLineNamesNoNewKeyAndTheOldValue" '[ "$(change_line retro.commit | cut -f2,3)" = "$(printf -- "-\tfalse")" ]'
check "Init_RetroCommitSet_ReportLineGivesAReason" '[ -n "$(change_line retro.commit | cut -f4)" ]'
check "Init_MigratedConfig_LabelIsTheManifestVersion" '[ "$(project_cfg config_version)" = "$copy_version" ]'
: > .git/info/exclude
check "Init_MigrationsFolder_IsIgnoredByGit" '[ -z "$(git status --porcelain --untracked-files=all -- .flow/migrations)" ]'
check "Init_StepThatChangesTheConfig_RunsBeforeTheFirstCopy" '[ "$(line_of ".flow/config.yaml: migrated" "$work/retro.out")" -lt "$(line_of ".flow/plugin.sh" "$work/retro.out")" ]'
cp .flow/config.yaml "$work/retro.once"; cp .flow/migrations/report.txt "$work/report.once"
/bin/ls -a .flow/migrations > "$work/migrations.once"
run_init >/dev/null 2>&1
check "Init_RunTwice_SecondRunLeavesTheConfig" 'cmp -s "$work/retro.once" .flow/config.yaml'
check "Init_RunTwice_SecondRunAddsNoReportLine" 'cmp -s "$work/report.once" .flow/migrations/report.txt'
check "Init_RunTwice_SecondRunAddsNoBackup" '[ "$(/bin/ls -a .flow/migrations)" = "$(cat "$work/migrations.once")" ]'

echo "the backup is named after the label found"
new_project labelled "config_version: $old_label\n${config_body}retro:\n  commit: false\n"
cp .flow/config.yaml "$work/labelled.before"
run_init >/dev/null 2>&1
check "Init_LabelledConfig_BackupHoldsTheOldFileUnderItsLabel" 'cmp -s "$work/labelled.before" ".flow/migrations/config.yaml.$old_label.bak"'
new_project taken "${config_body}retro:\n  commit: false\n"
cp .flow/config.yaml "$work/taken.before"
mkdir -p .flow/migrations && printf 'an older backup\n' > .flow/migrations/config.yaml.unversioned.bak
run_init >/dev/null 2>&1
check "Init_BackupNameTaken_WritesTheNextFreeName" 'cmp -s "$work/taken.before" .flow/migrations/config.yaml.unversioned.bak.2'
check "Init_BackupNameTaken_LeavesTheOlderBackup" '[ "$(cat .flow/migrations/config.yaml.unversioned.bak)" = "an older backup" ]'

echo "--check"
new_project pending "${config_body}retro:\n  commit: false\n"
tree_digest > "$work/pending.tree.before"
run_init --check > "$work/pending.out" 2>&1; pending_code=$?
check "InitCheck_PendingStep_NamesItAsDrift" 'grep -qF "drift: .flow/config.yaml: pending migration: retro.commit" "$work/pending.out"'
check "InitCheck_PendingStep_ExitsOne" '[ "$pending_code" = "$drift_exit" ]'
check "InitCheck_PendingStep_LeavesTheTreeUnchanged" '[ "$(tree_digest)" = "$(cat "$work/pending.tree.before")" ]'

echo "the owner's file as written"
new_project comments "# Mine, above everything.\n${config_body}# Above the retro map.\nretro:\n  # Inside the retro map.\n  commit: false\n# After the retro map.\nbase_note: kept\n"
grep '^[[:space:]]*#' .flow/config.yaml > "$work/comments.before"
run_init >/dev/null 2>&1
check "Init_CommentedConfig_IsMigrated" '[ -n "$(change_line retro.commit)" ]'
check "Init_OwnerComments_SurviveTheMigration" '[ "$(grep "^[[:space:]]*#" .flow/config.yaml)" = "$(cat "$work/comments.before")" ]'
carriage_return="$(printf '\r')"
new_project crlf "$(printf "${config_body}retro:\n  commit: false\n" | sed "s/\$/$carriage_return/")\n"
run_init >/dev/null 2>&1
check "Init_CrlfFile_IsMigrated" '[ -n "$(change_line retro.commit)" ]'
check "Init_CrlfFile_MigratedFileIsNotEmpty" '[ -s .flow/config.yaml ]'
check "Init_CrlfFile_KeepsItsLineEndings" '[ "$(grep -c "$carriage_return\$" .flow/config.yaml)" = "$(grep -c "" .flow/config.yaml)" ]'
new_project unterminated "${config_body}retro:\n  commit: false"
run_init >/dev/null 2>&1
check "Init_NoFinalNewline_IsMigrated" '[ -n "$(change_line retro.commit)" ]'
check "Init_NoFinalNewline_StaysUnterminated" '[ -n "$(tail -c 1 .flow/config.yaml)" ]'
new_project tabbed "${config_body}retro:\n\tcommit: false\n"
cp .flow/config.yaml "$work/tabbed.before"
run_init > "$work/tabbed.out" 2>&1
check "Init_TabIndentedConfig_RefusesAndLeavesTheFile" 'cmp -s "$work/tabbed.before" .flow/config.yaml'
check "Init_TabIndentedConfig_WritesNoBackup" '[ ! -e .flow/migrations ]'
check "Init_TabIndentedConfig_StillInstallsTheWrappers" '[ -x .flow/notify.sh ]'
check "Init_TabIndentedConfig_StillWritesTheStamp" '[ -f .flow/stamp ]'

echo "fixture step lists"
printf '{"steps": [{"name": "ready-needs-default", "op": "add", "key": "ready.needs", "value": ["priority"], "comment": "ready items need a priority", "reason": "a default the owner can see"}]}\n' > "$steps"
new_project added "config_version: $old_label\n${config_body}"
run_init >/dev/null 2>&1
check "Init_FixtureAddStep_WritesTheDefault" '[ "$(project_cfg ready.needs)" = priority ]'
check "Init_FixtureAddStep_WritesTheDefaultWithItsComment" 'grep -q "needs:.*# ready items need a priority" .flow/config.yaml'
printf '{"steps": [{"name": "retro-commit", "op": "remove", "key": "retro.commit", "reason": "first"}, {"name": "ready-needs-default", "op": "add", "key": "ready.needs", "value": ["priority"], "comment": "", "reason": "second"}]}\n' > "$steps"
new_project ordered "config_version: $old_label\n${config_body}retro:\n  commit: false\n"
run_init >/dev/null 2>&1
check "Init_TwoFixtureSteps_RunInListOrder" '[ "$(awk -F"\t" "NF > 1 { print \$4 }" .flow/migrations/report.txt | head -n 2 | tr "\n" " ")" = "first second " ]'
cp "$work/shipped-migrations.json" "$steps"

echo "a fresh install"
new_project fresh-install ''
rm .flow/config.yaml
run_init >/dev/null 2>&1
check "Init_FreshInstall_ConfigCarriesTheLabel" '[ "$(project_cfg config_version)" = "$copy_version" ]'
check "Init_FreshInstall_WritesNoBackup" '[ ! -e .flow/migrations ]'

[ "$fails" -eq 0 ] && { echo "config-migration: ok"; exit 0; }
echo "config-migration: $fails failed"; exit 1
