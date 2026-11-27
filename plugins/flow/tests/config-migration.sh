#!/bin/sh
# config-migration.sh: init brings an existing .flow/config.yaml to the plugin's migration steps,
# on a copy of the plugin in throwaway repos: the retro.commit removal as cfg reads it, the backup
# named after the label found, the report's change lines, --check as drift that changes nothing, a
# second run, the owner's comments and line endings, a refused file, a taken backup name, git
# status, the migration before the first copy, fixture step lists for add and step order, the
# label a fresh install writes, the session-start hook printing the report once, from the main
# worktree and a linked one, the two ready keys moving under ready as ready_rules reads them, and
# jobs.model and jobs.effort spread into each host's map as host_jobs_pair reads them, each with
# the fallback that still reads them unmoved, the comments around moved keys, an old label with
# nothing pending, --check on a refused file, a second migration after a plugin update, and a
# config another writer changes while init migrates it. Takes no argument. Exit 0 when every
# check passes, 1 on any failure.
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
run_start() { echo '{}' | FLOW_PLUGIN="$plugin_copy" "$start"; }
project_cfg() { (. "$plugin_copy/lib/flow.sh"; cfg "$1"); }
project_keys() { (. "$plugin_copy/lib/flow.sh"; yaml_keys .flow/config.yaml "$1"); }
# project_ready_needs, project_priority_order: the rule as ready_rules exports it, its warning unsaid.
project_ready_needs() { (unset FLOW_READY_WARNED; . "$plugin_copy/lib/flow.sh"; ready_rules 2>/dev/null; printf '%s' "$READY_NEEDS"); }
project_priority_order() { (unset FLOW_READY_WARNED; . "$plugin_copy/lib/flow.sh"; ready_rules 2>/dev/null; printf '%s' "$READY_PRIORITY_ORDER"); }
# change_line <old key>: the report line whose first field is the old key.
change_line() { awk -F'\t' -v key="$1" 'NF > 1 && $1 == key' .flow/migrations/report.txt; }
# change_line_to <old key> <new key>: the report line that moves the old key to the new one.
change_line_to() { awk -F'\t' -v old_key="$1" -v new_key="$2" 'NF > 1 && $1 == old_key && $2 == new_key' .flow/migrations/report.txt; }
# project_jobs_pair <host>, project_jobs_from <host>: the host's model and effort with a tab
# between, and the key prefix they come from, as host_jobs_pair reads them.
project_jobs_pair() { (. "$plugin_copy/lib/flow.sh"; . "$plugin_copy/lib/host.sh"; host_jobs_pair "$1"; printf '%s\t%s' "$jobs_model" "$jobs_effort"); }
project_jobs_from() { (. "$plugin_copy/lib/flow.sh"; . "$plugin_copy/lib/host.sh"; host_jobs_pair "$1"; printf '%s' "$jobs_from"); }
project_line() { (. "$plugin_copy/lib/flow.sh"; yaml_line .flow/config.yaml "$1"); }
# tree_digest: every file of the project outside .git with its content hash.
tree_digest() { find . -path ./.git -prune -o -type f -print | sort | while IFS= read -r project_file; do printf '%s %s\n' "$(content_hash "$project_file")" "$project_file"; done; }
content_hash() { shasum -a 256 < "$1" | cut -d' ' -f1; }
# line_of <pattern> <file>: the number of the first line holding the fixed text.
line_of() { grep -nF -- "$1" "$2" | head -n 1 | cut -d: -f1; }

echo "retro.commit is removed"
new_project retro "${config_body}retro:\n  commit: false\n"
cp .flow/config.yaml "$work/retro.before"
run_init > "$work/retro.out" 2>&1
check "Init_RetroCommitSet_CfgReadsItEmpty: cfg finds no retro.commit after init, because a key nothing reads only misleads the owner" '[ -z "$(project_cfg retro.commit)" ]'
check "Init_RetroCommitSet_RemovesTheKeyFromItsMap: the line is gone from the retro map, because the owner should not keep tuning a key nothing reads" '! project_keys retro | grep -qx commit'
check "Init_UnlabelledConfig_BackupHoldsTheOldFileAsUnversioned: the backup is the file as it was before init, because the owner restores from it when a migration goes wrong" 'cmp -s "$work/retro.before" .flow/migrations/config.yaml.unversioned.bak'
check "Init_RetroCommitSet_ReportLineHasFourTabSeparatedFields: the line splits into old key, new key, value and reason, because the hook and the owner read it field by field" '[ "$(change_line retro.commit | awk -F"\t" "{ print NF }")" = "$change_fields" ]'
check "Init_RetroCommitSet_ReportLineNamesNoNewKeyAndTheOldValue: a removal shows a dash and the dropped value, because the owner can put the value back by hand" '[ "$(change_line retro.commit | cut -f2,3)" = "$(printf -- "-\tfalse")" ]'
check "Init_RetroCommitSet_ReportLineGivesAReason: the reason field is filled, because the owner needs to know why their key changed" '[ -n "$(change_line retro.commit | cut -f4)" ]'
check "Init_MigratedConfig_LabelIsTheManifestVersion: the label is the plugin version that migrated, because the next backup is named after it" '[ "$(project_cfg config_version)" = "$copy_version" ]'
: > .git/info/exclude
check "Init_MigrationsFolder_IsIgnoredByGit: backups and the report stay out of git status, because the owner must not commit them by accident" '[ -z "$(git status --porcelain --untracked-files=all -- .flow/migrations)" ]'
check "Init_StepThatChangesTheConfig_RunsBeforeTheFirstCopy: the migration comes before the first copied file, because the copied scripts read the config in its new shape" '[ "$(line_of ".flow/config.yaml: migrated" "$work/retro.out")" -lt "$(line_of ".flow/plugin.sh" "$work/retro.out")" ]'
cp .flow/config.yaml "$work/retro.once"; cp .flow/migrations/report.txt "$work/report.once"
/bin/ls -a .flow/migrations > "$work/migrations.once"
run_init >/dev/null 2>&1
check "Init_RunTwice_SecondRunLeavesTheConfig: a second init leaves the file as the first wrote it, because init runs again on every update" 'cmp -s "$work/retro.once" .flow/config.yaml'
check "Init_RunTwice_SecondRunAddsNoReportLine: the report gains no line, because a repeated line would claim a change that never happened" 'cmp -s "$work/report.once" .flow/migrations/report.txt'
check "Init_RunTwice_SecondRunAddsNoBackup: no new backup appears, because it would only copy a file already migrated" '[ "$(/bin/ls -a .flow/migrations)" = "$(cat "$work/migrations.once")" ]'

echo "the backup is named after the label found"
new_project labelled "config_version: $old_label\n${config_body}retro:\n  commit: false\n"
cp .flow/config.yaml "$work/labelled.before"
run_init >/dev/null 2>&1
check "Init_LabelledConfig_BackupHoldsTheOldFileUnderItsLabel: the backup carries the old label in its name, because the owner restores by the version they had" 'cmp -s "$work/labelled.before" ".flow/migrations/config.yaml.$old_label.bak"'
new_project taken "${config_body}retro:\n  commit: false\n"
cp .flow/config.yaml "$work/taken.before"
mkdir -p .flow/migrations && printf 'an older backup\n' > .flow/migrations/config.yaml.unversioned.bak
run_init >/dev/null 2>&1
check "Init_BackupNameTaken_WritesTheNextFreeName: a taken name gets the next number, because an earlier backup must not be overwritten" 'cmp -s "$work/taken.before" .flow/migrations/config.yaml.unversioned.bak.2'
check "Init_BackupNameTaken_LeavesTheOlderBackup: the older backup keeps its content, because it may be the only copy of an older config" '[ "$(cat .flow/migrations/config.yaml.unversioned.bak)" = "an older backup" ]'

echo "--check"
new_project pending "${config_body}retro:\n  commit: false\n"
tree_digest > "$work/pending.tree.before"
run_init --check > "$work/pending.out" 2>&1; pending_code=$?
check "InitCheck_PendingStep_NamesItAsDrift: --check lists the pending step, because the owner sees what init would change before it does" 'grep -qF "drift: .flow/config.yaml: pending migration: retro.commit" "$work/pending.out"'
check "InitCheck_PendingStep_ExitsOne: a pending step exits as drift, because a caller reads the exit code, not the text" '[ "$pending_code" = "$drift_exit" ]'
check "InitCheck_PendingStep_LeavesTheTreeUnchanged: no file changes, because --check only reports" '[ "$(tree_digest)" = "$(cat "$work/pending.tree.before")" ]'

echo "the owner's file as written"
new_project comments "# Mine, above everything.\n${config_body}# Above the retro map.\nretro:\n  # Inside the retro map.\n  commit: false\n# After the retro map.\nbase_note: kept\n"
grep '^[[:space:]]*#' .flow/config.yaml > "$work/comments.before"
run_init >/dev/null 2>&1
check "Init_CommentedConfig_IsMigrated: the commented file still migrates, because the comment check below means nothing on an untouched file" '[ -n "$(change_line retro.commit)" ]'
check "Init_OwnerComments_SurviveTheMigration: every comment line is kept in order, because the owner's notes are theirs" '[ "$(grep "^[[:space:]]*#" .flow/config.yaml)" = "$(cat "$work/comments.before")" ]'
carriage_return="$(printf '\r')"
new_project crlf "$(printf "${config_body}retro:\n  commit: false\n" | sed "s/\$/$carriage_return/")\n"
run_init >/dev/null 2>&1
check "Init_CrlfFile_IsMigrated: a CRLF file migrates, because editors on Windows write CRLF" '[ -n "$(change_line retro.commit)" ]'
check "Init_CrlfFile_MigratedFileIsNotEmpty: the migrated file keeps its content, because an empty config loses every setting" '[ -s .flow/config.yaml ]'
check "Init_CrlfFile_KeepsItsLineEndings: every line still ends in CRLF, because mixed endings show the whole file as changed" '[ "$(grep -c "$carriage_return\$" .flow/config.yaml)" = "$(grep -c "" .flow/config.yaml)" ]'
new_project unterminated "${config_body}retro:\n  commit: false"
run_init >/dev/null 2>&1
check "Init_NoFinalNewline_IsMigrated: a file without a final newline migrates, because hand-edited files often end that way" '[ -n "$(change_line retro.commit)" ]'
check "Init_NoFinalNewline_StaysUnterminated: no newline is added at the end, because init changes only what a step touches" '[ -n "$(tail -c 1 .flow/config.yaml)" ]'
new_project tabbed "${config_body}retro:\n\tcommit: false\n"
cp .flow/config.yaml "$work/tabbed.before"
run_init > "$work/tabbed.out" 2>&1
check "Init_TabIndentedConfig_RefusesAndLeavesTheFile: a tab-indented file stays as written, because a guessed edit could break the owner's config" 'cmp -s "$work/tabbed.before" .flow/config.yaml'
check "Init_TabIndentedConfig_WritesNoBackup: no migrations folder appears, because nothing changed" '[ ! -e .flow/migrations ]'
check "Init_TabIndentedConfig_StillInstallsTheWrappers: the wrappers are installed, because a refused migration must not block the install" '[ -x .flow/notify.sh ]'
check "Init_TabIndentedConfig_StillWritesTheStamp: the stamp is written, because without it every session asks for init again" '[ -f .flow/stamp ]'

echo "fixture step lists"
printf '{"steps": [{"name": "ready-needs-default", "op": "add", "key": "ready.needs", "value": ["priority"], "comment": "ready items need a priority", "reason": "a default the owner can see"}]}\n' > "$steps"
new_project added "config_version: $old_label\n${config_body}"
run_init >/dev/null 2>&1
check "Init_FixtureAddStep_WritesTheDefault: the added key holds the step's value, because the readers take the default from the file" '[ "$(project_cfg ready.needs)" = priority ]'
check "Init_FixtureAddStep_WritesTheDefaultWithItsComment: the step's comment goes with the key, because it tells the owner what the key does" 'grep -q "needs:.*# ready items need a priority" .flow/config.yaml'
printf '{"steps": [{"name": "retro-commit", "op": "remove", "key": "retro.commit", "reason": "first"}, {"name": "ready-needs-default", "op": "add", "key": "ready.needs", "value": ["priority"], "comment": "", "reason": "second"}]}\n' > "$steps"
new_project ordered "config_version: $old_label\n${config_body}retro:\n  commit: false\n"
run_init >/dev/null 2>&1
check "Init_TwoFixtureSteps_RunInListOrder: steps run in the order listed, because a later step may build on an earlier one" '[ "$(awk -F"\t" "NF > 1 { print \$4 }" .flow/migrations/report.txt | head -n 2 | tr "\n" " ")" = "first second " ]'
cp "$work/shipped-migrations.json" "$steps"

echo "a fresh install"
new_project fresh-install ''
rm .flow/config.yaml
run_init >/dev/null 2>&1
check "Init_FreshInstall_ConfigCarriesTheLabel: a new config has the label, because the first update would otherwise treat it as unversioned" '[ "$(project_cfg config_version)" = "$copy_version" ]'
check "Init_FreshInstall_WritesNoBackup: no migrations folder on a fresh install, because there was no older file to keep" '[ ! -e .flow/migrations ]'
run_start > "$work/fresh-install.start" 2>&1
check "SessionStart_NoReport_PrintsNothing: a session with no report is quiet, because noise at every start hides what matters" '[ ! -s "$work/fresh-install.start" ]'

echo "session start prints the report once"
new_project printed "${config_body}retro:\n  commit: false\n"
run_init >/dev/null 2>&1
cp .flow/migrations/report.txt "$work/printed.report"
run_start > "$work/printed.first" 2>&1
run_start > "$work/printed.second" 2>&1
check "Init_BeforeTheFirstStart_IsMigrated: the config migrates, because the print checks below need a report" '[ -n "$(change_line retro.commit)" ]'
check "SessionStart_AfterAMigratingInit_PrintsTheReportLines: the first session shows the change, because the owner must learn their config changed" 'grep -qF -- "$(change_line retro.commit)" "$work/printed.first"'
check "SessionStart_SecondStart_PrintsNothing: the report shows once, because the same lines every session would be noise" '[ ! -s "$work/printed.second" ]'
check "SessionStart_ReportPrinted_ReportTxtStays: the report file is kept, because the owner may read it again later" 'cmp -s "$work/printed.report" .flow/migrations/report.txt'
new_project pooled "${config_body}retro:\n  commit: false\n"
run_init >/dev/null 2>&1
git worktree add -q -b pool "$work/pooled-worktree" || exit 1
(cd "$work/pooled-worktree" || exit 1; run_start) > "$work/pooled.start" 2>&1
check "Init_MainWorktreeOfAPool_IsMigrated: the main worktree migrates, because the pool check below needs its report" '[ -n "$(change_line retro.commit)" ]'
check "SessionStart_FromAPoolWorktree_PrintsTheMainWorktreesReport: a session in a pool worktree shows it, because the owner often starts sessions there" 'grep -qF -- "$(change_line retro.commit)" "$work/pooled.start"'

echo "the ready keys move under ready"
needs_written=priority,size
order_written=P1,P0,P2
new_project ready-unmigrated "${config_body}github:\n  repo: acme/widgets\n  ready_needs: [priority, size]\n  priority_order: [P1, P0, P2]\n"
check "ReadyRules_UnmigratedConfig_StillReadsTheOldReadyNeeds: github.ready_needs still counts before init, because a project not yet migrated must keep its ready rule" '[ "$(project_ready_needs)" = "$needs_written" ]'
check "ReadyRules_UnmigratedConfig_StillReadsTheOldPriorityOrder: github.priority_order still counts before init, because a project not yet migrated must keep its queue order" '[ "$(project_priority_order)" = "$order_written" ]'
new_project ready-inline "${config_body}github:\n  repo: acme/widgets\n  ready_needs: [priority, size]\n"
needs_before="$(project_ready_needs)"
run_init >/dev/null 2>&1
check "Init_ReadyNeedsInline_MovesUnderReady: the inline list lands at ready.needs, because that is the key the readers now take" '[ "$(project_cfg ready.needs | paste -sd, -)" = "$needs_written" ]'
check "Init_ReadyNeedsInline_LeavesNoOldKey: github.ready_needs is gone, because two copies of one setting drift apart" '! project_keys github | grep -qx ready_needs'
check "Init_ReadyNeedsInline_ReadyRulesReadsTheSame: ready_rules gives the needs it gave before, because a migration must not change which items are ready" '[ "$(project_ready_needs)" = "$needs_before" ]'
new_project ready-block "${config_body}github:\n  repo: acme/widgets\n  ready_needs:\n    - priority\n    - size\n"
needs_before="$(project_ready_needs)"
run_init >/dev/null 2>&1
check "Init_ReadyNeedsBlockList_MovesUnderReady: the block list lands at ready.needs, because that is the key the readers now take" '[ "$(project_cfg ready.needs | paste -sd, -)" = "$needs_written" ]'
check "Init_ReadyNeedsBlockList_ReadyRulesReadsTheSame: ready_rules gives the needs it gave before, because a migration must not change which items are ready" '[ "$(project_ready_needs)" = "$needs_before" ]'
new_project priority-order "${config_body}github:\n  repo: acme/widgets\n  priority_order: [P1, P0, P2]\n"
order_before="$(project_priority_order)"
run_init >/dev/null 2>&1
check "Init_PriorityOrder_MovesUnderReady: the order lands at ready.priority_order, because that is the key the readers now take" '[ "$(project_cfg ready.priority_order | paste -sd, -)" = "$order_written" ]'
check "Init_PriorityOrder_ReadyRulesReadsTheSame: ready_rules gives the order it gave before, because a migration must not reorder the owner's queue" '[ "$(project_priority_order)" = "$order_before" ]'
new_project ready-set-empty "${config_body}ready:\n  needs: []\ngithub:\n  repo: acme/widgets\n  ready_needs: [priority]\n"
needs_before="$(project_ready_needs)"
run_init >/dev/null 2>&1
check "Init_ReadyNeedsAlreadySetEmpty_IsMigrated: the old key is still handled, because a leftover old key would stay pending forever" '[ -n "$(change_line github.ready_needs)" ]'
check "Init_ReadyNeedsAlreadySetEmpty_KeepsTheNewKey: ready.needs stays as set, because the owner's own setting wins" 'project_keys ready | grep -qx needs'
check "Init_ReadyNeedsAlreadySetEmpty_DropsTheOldKey: github.ready_needs is gone, because two copies of one setting drift apart" '! project_keys github | grep -qx ready_needs'
check "Init_ReadyNeedsAlreadySetEmpty_ReadyRulesReadsTheSame: ready_rules gives the needs it gave before, because a migration must not change which items are ready" '[ "$(project_ready_needs)" = "$needs_before" ]'
check "Init_ReadyNeedsAlreadySetEmpty_ReportLineMovesItNowhere: the line shows a dash as the new key, because the value was dropped, not moved" '[ "$(change_line github.ready_needs | cut -f2)" = - ]'
new_project ready-comments "${config_body}ready:\n  # needs: [priority]  # an example\n  # The priority is a label.\ngithub:\n  repo: acme/widgets\n  ready_needs: [priority, size]\n"
needs_before="$(project_ready_needs)"
run_init >/dev/null 2>&1
check "Init_ReadyMapHoldsOnlyComments_ReadyRulesReadsTheSame: ready_rules gives the needs it gave before, because a migration must not change which items are ready" '[ "$(project_ready_needs)" = "$needs_before" ]'
check "Init_ReadyMapHoldsOnlyComments_AddsTheKeyAfterThem: the key goes below the owner's comments, because those comments introduce the map" '[ "$(line_of "  needs:" .flow/config.yaml)" -gt "$(line_of "# The priority is a label." .flow/config.yaml)" ]'
new_project github-emptied "${config_body}github:\n  ready_needs: [priority, size]\n  priority_order: [P1, P0, P2]\n"
run_init >/dev/null 2>&1
check "Init_GithubLeftEmpty_ReadyRulesReadsTheWrittenNeeds: the moved needs still read, because removing the emptied map must not lose them" '[ "$(project_ready_needs)" = "$needs_written" ]'
check "Init_GithubLeftEmpty_RemovesItsLine: the emptied github map goes, because an empty map reads as a setting nobody made" '! grep -q "^github:" .flow/config.yaml'
check "Init_TwoReadyMoves_ReportHasTheReadyNeedsLine: the ready_needs move is listed, because the report lists every change init made" '[ "$(change_line github.ready_needs | cut -f2)" = ready.needs ]'
check "Init_TwoReadyMoves_ReportHasThePriorityOrderLine: the priority_order move is listed, because the report lists every change init made" '[ "$(change_line github.priority_order | cut -f2)" = ready.priority_order ]'

echo "jobs.model and jobs.effort spread into each host's map"
model_written=opus
effort_written=high
new_project jobs-unmigrated "${config_body}jobs:\n  model: $model_written\n  effort: $effort_written\n"
check "HostJobsPair_UnmigratedConfig_ClaudeStillReadsTheOldPair: jobs.model and jobs.effort still apply to claude before init, because a project not yet migrated must keep its job settings" '[ "$(project_jobs_pair claude)" = "$(printf "%s\t%s" "$model_written" "$effort_written")" ]'
check "HostJobsPair_UnmigratedConfig_CodexStillReadsTheOldEffort: jobs.effort still applies to codex before init, because a project not yet migrated must keep its job settings" '[ "$(project_jobs_pair codex | cut -f2)" = "$effort_written" ]'
new_project jobs-no-host-maps "${config_body}jobs:\n  model: $model_written\n  effort: $effort_written\n"
claude_before="$(project_jobs_pair claude)"; codex_before="$(project_jobs_pair codex)"
run_init >/dev/null 2>&1
check "Init_NoHostMaps_ClaudeReadsItsOwnMap: claude reads jobs.claude, because the old pair now lives there" '[ "$(project_jobs_from claude)" = jobs.claude ]'
check "Init_NoHostMaps_ClaudeGetsTheOldPairAsWritten: claude's pair is unchanged, because a migration must not change how the jobs run" '[ "$(project_jobs_pair claude)" = "$claude_before" ]'
check "Init_NoHostMaps_CodexReadsItsOwnMap: codex reads jobs.codex, because the old pair now lives there" '[ "$(project_jobs_from codex)" = jobs.codex ]'
check "Init_NoHostMaps_CodexReadsTheSamePair: codex's pair is unchanged, because a migration must not change how the jobs run" '[ "$(project_jobs_pair codex)" = "$codex_before" ]'
check "Init_NoHostMaps_OldModelGoes: jobs.model is gone, because two copies of one setting drift apart" '! project_keys jobs | grep -qx model'
check "Init_NoHostMaps_OldEffortGoes: jobs.effort is gone, because two copies of one setting drift apart" '! project_keys jobs | grep -qx effort'
check "Init_NoHostMaps_ReportHasALineForClaudesModel: the old model lands in claude's map, because the report lists every change init made" '[ -n "$(change_line_to jobs.model jobs.claude.model)" ]'
check "Init_NoHostMaps_ReportHasALineForCodexsModel: the old model lands in codex's map, because the report lists every change init made" '[ -n "$(change_line_to jobs.model jobs.codex.model)" ]'
check "Init_NoHostMaps_ReportHasALineForClaudesEffort: the old effort lands in claude's map, because the report lists every change init made" '[ -n "$(change_line_to jobs.effort jobs.claude.effort)" ]'
check "Init_NoHostMaps_ReportHasALineForCodexsEffort: the old effort lands in codex's map, because the report lists every change init made" '[ -n "$(change_line_to jobs.effort jobs.codex.effort)" ]'
for roster_name in Sonnet Opus Fable Haiku; do
  roster_model="$(printf '%s' "$roster_name" | tr '[:upper:]' '[:lower:]')"
  new_project "jobs-$roster_model" "${config_body}jobs:\n  model: $roster_model\n"
  codex_before="$(project_jobs_pair codex)"
  run_init >/dev/null 2>&1
  check "Init_NoHostMapsOldModel${roster_name}_CodexReadsItsOwnMap: codex reads jobs.codex, because the mapped model now lives there" '[ "$(project_jobs_from codex)" = jobs.codex ]'
  check "Init_NoHostMapsOldModel${roster_name}_CodexGetsTheMappedModel: codex runs the model it ran before, because codex cannot run a claude model name" '[ "$(project_jobs_pair codex)" = "$codex_before" ]'
done
new_project jobs-claude-map "${config_body}jobs:\n  model: $model_written\n  effort: $effort_written\n  claude:\n    model: claude-own\n"
claude_before="$(project_jobs_pair claude)"; codex_before="$(project_jobs_pair codex)"
run_init >/dev/null 2>&1
check "Init_ClaudeMapOnly_CodexReadsItsOwnMap: codex reads jobs.codex, because the old pair now lives there" '[ "$(project_jobs_from codex)" = jobs.codex ]'
check "Init_ClaudeMapOnly_CodexReadsTheSamePair: codex's pair is unchanged, because a migration must not change how the jobs run" '[ "$(project_jobs_pair codex)" = "$codex_before" ]'
check "Init_ClaudeMapOnly_ClaudeReadsTheSamePair: claude keeps its own map's pair, because the owner's host map wins over the old pair" '[ "$(project_jobs_pair claude)" = "$claude_before" ]'
check "Init_ClaudeMapOnly_ReportHasNoLineForClaudesModel: nothing is listed for claude's model, because the report lists only changes init made" '[ -z "$(change_line_to jobs.model jobs.claude.model)" ]'
check "Init_ClaudeMapOnly_ReportHasNoLineForClaudesEffort: nothing is listed for claude's effort, because the report lists only changes init made" '[ -z "$(change_line_to jobs.effort jobs.claude.effort)" ]'
new_project jobs-both-maps "${config_body}jobs:\n  model: $model_written\n  effort: $effort_written\n  claude:\n    model: claude-own\n  codex:\n    effort: low\n"
claude_before="$(project_jobs_pair claude)"; codex_before="$(project_jobs_pair codex)"
run_init >/dev/null 2>&1
check "Init_BothHostMaps_OldModelGoes: jobs.model is gone, because a key nothing reads only misleads the owner" '! project_keys jobs | grep -qx model'
check "Init_BothHostMaps_OldEffortGoes: jobs.effort is gone, because a key nothing reads only misleads the owner" '! project_keys jobs | grep -qx effort'
check "Init_BothHostMaps_ClaudeReadsTheSamePair: claude's pair is unchanged, because the owner's host map wins over the old pair" '[ "$(project_jobs_pair claude)" = "$claude_before" ]'
check "Init_BothHostMaps_CodexReadsTheSamePair: codex's pair is unchanged, because the owner's host map wins over the old pair" '[ "$(project_jobs_pair codex)" = "$codex_before" ]'
check "Init_BothHostMaps_ReportLineMovesTheOldModelNowhere: the line shows a dash as the new key, because the value was dropped, not moved" '[ "$(change_line jobs.model | cut -f2)" = - ]'
new_project jobs-only-model "${config_body}jobs:\n  model: $model_written\n"
run_init >/dev/null 2>&1
check "Init_OnlyOldModel_ClaudeReadsItsOwnMap: claude reads jobs.claude, because the old model now lives there" '[ "$(project_jobs_from claude)" = jobs.claude ]'
check "Init_OnlyOldModel_NoClaudeEffortKeyIsWritten: no effort appears in claude's map, because an invented effort would change how the jobs run" '! project_keys jobs.claude | grep -qx effort'
check "Init_OnlyOldModel_NoCodexEffortKeyIsWritten: no effort appears in codex's map, because an invented effort would change how the jobs run" '! project_keys jobs.codex | grep -qx effort'
new_project jobs-quoted "${config_body}jobs:\n  model: \"$model_written\"\n"
codex_before="$(project_jobs_pair codex)"
run_init >/dev/null 2>&1
check "Init_QuotedOldModel_KeepsItsQuotesInBothMaps: both copies stay quoted, because init keeps values as the owner wrote them" '[ "$(grep -c "^    model: \".*\"\$" .flow/config.yaml)" = 2 ]'
check "Init_QuotedOldModel_CodexGetsTheMappedModel: quotes do not stop the mapping, because codex cannot run a claude model name" '[ "$(project_jobs_pair codex)" = "$codex_before" ]'
new_project jobs-commented "${config_body}jobs:\n  model: $model_written  # the roster default\n"
run_init >/dev/null 2>&1
check "Init_OldModelWithTrailingComment_CommentOnEveryTarget: each copy keeps the comment, because the owner's notes are theirs" '[ "$(grep -c "^    model: .*  # the roster default\$" .flow/config.yaml)" = 2 ]'
new_project jobs-codex-max "${config_body}jobs:\n  host: codex\n  model: $model_written\n  effort: max\n"
run_init > "$work/jobs-codex-max.out" 2>&1
check "Init_OldEffortMaxOnACodexProject_GapNamesTheMigratedLine: the gap points at the line in jobs.codex, because the owner fixes the line the gap names" 'grep -qF ".flow/config.yaml:$(project_line jobs.codex.effort): jobs.codex.effort is max;" "$work/jobs-codex-max.out"'

echo "comments around the keys that move"
new_project moved-comments "${config_body}# Above github.\ngithub:\n  # Inside github, above the repo.\n  repo: acme/widgets\n  # Above ready_needs.\n  ready_needs: [priority, size]\n# Above jobs.\njobs:\n  # Inside jobs.\n  model: $model_written\n# At the end.\n"
grep '^[[:space:]]*#' .flow/config.yaml > "$work/moved-comments.before"
run_init >/dev/null 2>&1
grep '^[[:space:]]*#' .flow/config.yaml > "$work/moved-comments.after"
check "Init_CommentsAroundMovedKeys_IsMigrated: the ready key moved, because the comment check below means nothing on an untouched file" '[ -n "$(change_line github.ready_needs)" ]'
check "Init_CommentsAroundMovedKeys_EveryCommentLineSurvives: no comment line around the moved and spread keys is lost, because the owner's notes are theirs" '! grep -vxFf "$work/moved-comments.after" "$work/moved-comments.before"'

echo "a labelled config with nothing pending"
new_project nothing-pending "config_version: $old_label\n${config_body}"
cp .flow/config.yaml "$work/nothing-pending.before"
run_init >/dev/null 2>&1
check "Init_OldLabelNothingPending_LeavesTheBytes: an old label with no pending step stays as written, because init rewrites the label only with a change" 'cmp -s "$work/nothing-pending.before" .flow/config.yaml'
check "Init_OldLabelNothingPending_WritesNoMigrationsFolder: no backup or report appears, because there was no change to record" '[ ! -e .flow/migrations ]'
run_init --check > "$work/nothing-pending.check" 2>&1
check "InitCheck_NothingPending_ListsNoPendingMigration: a config with nothing to migrate shows no migration drift, because drift means work init would do" '! grep -qF "pending migration" "$work/nothing-pending.check"'

echo "--check on a refused config"
new_project check-tabbed "${config_body}retro:\n\tcommit: false\n"
tree_digest > "$work/check-tabbed.tree.before"
run_init --check >/dev/null 2>&1
check "InitCheck_RefusedConfig_LeavesTheTreeUnchanged: a file outside the subset changes nothing under --check, because --check never writes" '[ "$(tree_digest)" = "$(cat "$work/check-tabbed.tree.before")" ]'

echo "a second migration after a plugin update"
manifest="$plugin_copy/.claude-plugin/plugin.json"
cp "$manifest" "$work/manifest.shipped"
updated_version=99.0.0
new_project second-migration "${config_body}retro:\n  commit: false\n"
run_init >/dev/null 2>&1
run_start >/dev/null 2>&1
sed "s/\"version\": \"$copy_version\"/\"version\": \"$updated_version\"/" "$work/manifest.shipped" > "$manifest"
printf 'github:\n  ready_needs: [priority]\n' >> .flow/config.yaml
cp .flow/config.yaml "$work/second-migration.before"
run_init >/dev/null 2>&1
run_start > "$work/second-migration.start" 2>&1
cp "$work/manifest.shipped" "$manifest"
check "Init_SecondMigration_BackupNamedAfterTheLabelTheFirstWrote: the backup carries the version migrated from, because the owner restores by the version they had" 'cmp -s "$work/second-migration.before" ".flow/migrations/config.yaml.$copy_version.bak"'
check "Init_SecondMigration_LabelBecomesTheUpdatedVersion: the label moves to the updated plugin's version, because the next backup is named after it" '[ "$(project_cfg config_version)" = "$updated_version" ]'
check "SessionStart_AfterASecondMigration_PrintsTheNewChange: the second report prints, because each new report is shown once" 'grep -qF -- "$(change_line github.ready_needs)" "$work/second-migration.start"'
check "SessionStart_AfterASecondMigration_LeavesOutTheEarlierChange: the first report is not shown again, because it was printed already" '! grep -qF -- "$(change_line retro.commit)" "$work/second-migration.start"'

echo "a config that changes while init migrates it"
helper="$plugin_copy/scripts/_config_migration.py"
cp "$helper" "$work/shipped-helper.py"
cp "$helper" "$plugin_copy/scripts/_config_migration_shipped.py"
cat > "$helper" <<EOF_CHANGING_HELPER
import subprocess, sys
code = subprocess.run([sys.executable, "-I", "$plugin_copy/scripts/_config_migration_shipped.py", *sys.argv[1:]]).returncode
if sys.argv[1] == "apply":
    open(sys.argv[3], "a").write("pool_entry_added: meanwhile\\n")
sys.exit(code)
EOF_CHANGING_HELPER
new_project changed-meanwhile "${config_body}retro:\n  commit: false\n"
{ cat .flow/config.yaml; printf 'pool_entry_added: meanwhile\n'; } > "$work/changed-meanwhile.expected"
run_init > "$work/changed-meanwhile.out" 2>&1
cp "$work/shipped-helper.py" "$helper"
check "Init_ConfigChangedWhileMigrating_KeepsTheOtherWritersChange: the config holds what the other writer wrote, because a migration from a stale read would drop a new pool entry" 'cmp -s "$work/changed-meanwhile.expected" .flow/config.yaml'
check "Init_ConfigChangedWhileMigrating_WritesNoBackupOrReport: no migrations folder appears, because a backup and report lines for a refused migration would claim a change that never happened" '[ ! -e .flow/migrations ]'
check "Init_ConfigChangedWhileMigrating_NotesToRunInitAgain: the output names the config and asks for another init, because the owner must learn it is not migrated" 'grep -qF ".flow/config.yaml changed while init migrated it" "$work/changed-meanwhile.out"'
run_init >/dev/null 2>&1
check "Init_AfterARefusedMigration_RunAgainMigrates: the next init migrates the changed config, because the refusal must leave nothing that blocks a retry" '[ -n "$(change_line retro.commit)" ]'

[ "$fails" -eq 0 ] && { echo "config-migration: ok"; exit 0; }
echo "config-migration: $fails failed"; exit 1
