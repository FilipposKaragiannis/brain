#!/bin/sh
# config-migration.sh: init brings an existing .flow/config.yaml to the plugin's migration steps,
# on a copy of the plugin in throwaway repos: the retro.commit removal as cfg reads it, the backup
# named after the label found, the report's change lines, --check as drift that changes nothing, a
# second run, the owner's comments and line endings, a refused file, a taken backup name, git
# status, the migration before the first copy, fixture step lists for add and step order, the
# label a fresh install writes, the session-start hook printing the report once, from the main
# worktree and a linked one, the two ready keys moving under ready as ready_rules reads them, and
# jobs.model and jobs.effort spread into each host's map as host_jobs_pair reads them, each with
# the fallback that still reads them unmoved. Takes no argument. Exit 0 when every check passes, 1
# on any failure.
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
run_start > "$work/fresh-install.start" 2>&1
check "SessionStart_NoReport_PrintsNothing" '[ ! -s "$work/fresh-install.start" ]'

echo "session start prints the report once"
new_project printed "${config_body}retro:\n  commit: false\n"
run_init >/dev/null 2>&1
cp .flow/migrations/report.txt "$work/printed.report"
run_start > "$work/printed.first" 2>&1
run_start > "$work/printed.second" 2>&1
check "Init_BeforeTheFirstStart_IsMigrated" '[ -n "$(change_line retro.commit)" ]'
check "SessionStart_AfterAMigratingInit_PrintsTheReportLines" 'grep -qF -- "$(change_line retro.commit)" "$work/printed.first"'
check "SessionStart_SecondStart_PrintsNothing" '[ ! -s "$work/printed.second" ]'
check "SessionStart_ReportPrinted_ReportTxtStays" 'cmp -s "$work/printed.report" .flow/migrations/report.txt'
new_project pooled "${config_body}retro:\n  commit: false\n"
run_init >/dev/null 2>&1
git worktree add -q -b pool "$work/pooled-worktree" || exit 1
(cd "$work/pooled-worktree" || exit 1; run_start) > "$work/pooled.start" 2>&1
check "Init_MainWorktreeOfAPool_IsMigrated" '[ -n "$(change_line retro.commit)" ]'
check "SessionStart_FromAPoolWorktree_PrintsTheMainWorktreesReport" 'grep -qF -- "$(change_line retro.commit)" "$work/pooled.start"'

echo "the ready keys move under ready"
needs_written=priority,size
order_written=P1,P0,P2
new_project ready-unmigrated "${config_body}github:\n  repo: acme/widgets\n  ready_needs: [priority, size]\n  priority_order: [P1, P0, P2]\n"
check "ReadyRules_UnmigratedConfig_StillReadsTheOldReadyNeeds" '[ "$(project_ready_needs)" = "$needs_written" ]'
check "ReadyRules_UnmigratedConfig_StillReadsTheOldPriorityOrder" '[ "$(project_priority_order)" = "$order_written" ]'
new_project ready-inline "${config_body}github:\n  repo: acme/widgets\n  ready_needs: [priority, size]\n"
needs_before="$(project_ready_needs)"
run_init >/dev/null 2>&1
check "Init_ReadyNeedsInline_MovesUnderReady" '[ "$(project_cfg ready.needs | paste -sd, -)" = "$needs_written" ]'
check "Init_ReadyNeedsInline_LeavesNoOldKey" '! project_keys github | grep -qx ready_needs'
check "Init_ReadyNeedsInline_ReadyRulesReadsTheSame" '[ "$(project_ready_needs)" = "$needs_before" ]'
new_project ready-block "${config_body}github:\n  repo: acme/widgets\n  ready_needs:\n    - priority\n    - size\n"
needs_before="$(project_ready_needs)"
run_init >/dev/null 2>&1
check "Init_ReadyNeedsBlockList_MovesUnderReady" '[ "$(project_cfg ready.needs | paste -sd, -)" = "$needs_written" ]'
check "Init_ReadyNeedsBlockList_ReadyRulesReadsTheSame" '[ "$(project_ready_needs)" = "$needs_before" ]'
new_project priority-order "${config_body}github:\n  repo: acme/widgets\n  priority_order: [P1, P0, P2]\n"
order_before="$(project_priority_order)"
run_init >/dev/null 2>&1
check "Init_PriorityOrder_MovesUnderReady" '[ "$(project_cfg ready.priority_order | paste -sd, -)" = "$order_written" ]'
check "Init_PriorityOrder_ReadyRulesReadsTheSame" '[ "$(project_priority_order)" = "$order_before" ]'
new_project ready-set-empty "${config_body}ready:\n  needs: []\ngithub:\n  repo: acme/widgets\n  ready_needs: [priority]\n"
needs_before="$(project_ready_needs)"
run_init >/dev/null 2>&1
check "Init_ReadyNeedsAlreadySetEmpty_IsMigrated" '[ -n "$(change_line github.ready_needs)" ]'
check "Init_ReadyNeedsAlreadySetEmpty_KeepsTheNewKey" 'project_keys ready | grep -qx needs'
check "Init_ReadyNeedsAlreadySetEmpty_DropsTheOldKey" '! project_keys github | grep -qx ready_needs'
check "Init_ReadyNeedsAlreadySetEmpty_ReadyRulesReadsTheSame" '[ "$(project_ready_needs)" = "$needs_before" ]'
check "Init_ReadyNeedsAlreadySetEmpty_ReportLineMovesItNowhere" '[ "$(change_line github.ready_needs | cut -f2)" = - ]'
new_project ready-comments "${config_body}ready:\n  # needs: [priority]  # an example\n  # The priority is a label.\ngithub:\n  repo: acme/widgets\n  ready_needs: [priority, size]\n"
needs_before="$(project_ready_needs)"
run_init >/dev/null 2>&1
check "Init_ReadyMapHoldsOnlyComments_ReadyRulesReadsTheSame" '[ "$(project_ready_needs)" = "$needs_before" ]'
check "Init_ReadyMapHoldsOnlyComments_AddsTheKeyAfterThem" '[ "$(line_of "  needs:" .flow/config.yaml)" -gt "$(line_of "# The priority is a label." .flow/config.yaml)" ]'
new_project github-emptied "${config_body}github:\n  ready_needs: [priority, size]\n  priority_order: [P1, P0, P2]\n"
run_init >/dev/null 2>&1
check "Init_GithubLeftEmpty_ReadyRulesReadsTheWrittenNeeds" '[ "$(project_ready_needs)" = "$needs_written" ]'
check "Init_GithubLeftEmpty_RemovesItsLine" '! grep -q "^github:" .flow/config.yaml'
check "Init_TwoReadyMoves_ReportHasTheReadyNeedsLine" '[ "$(change_line github.ready_needs | cut -f2)" = ready.needs ]'
check "Init_TwoReadyMoves_ReportHasThePriorityOrderLine" '[ "$(change_line github.priority_order | cut -f2)" = ready.priority_order ]'

echo "jobs.model and jobs.effort spread into each host's map"
model_written=opus
effort_written=high
new_project jobs-unmigrated "${config_body}jobs:\n  model: $model_written\n  effort: $effort_written\n"
check "HostJobsPair_UnmigratedConfig_ClaudeStillReadsTheOldPair" '[ "$(project_jobs_pair claude)" = "$(printf "%s\t%s" "$model_written" "$effort_written")" ]'
check "HostJobsPair_UnmigratedConfig_CodexStillReadsTheOldEffort" '[ "$(project_jobs_pair codex | cut -f2)" = "$effort_written" ]'
new_project jobs-no-host-maps "${config_body}jobs:\n  model: $model_written\n  effort: $effort_written\n"
claude_before="$(project_jobs_pair claude)"; codex_before="$(project_jobs_pair codex)"
run_init >/dev/null 2>&1
check "Init_NoHostMaps_ClaudeReadsItsOwnMap" '[ "$(project_jobs_from claude)" = jobs.claude ]'
check "Init_NoHostMaps_ClaudeGetsTheOldPairAsWritten" '[ "$(project_jobs_pair claude)" = "$claude_before" ]'
check "Init_NoHostMaps_CodexReadsItsOwnMap" '[ "$(project_jobs_from codex)" = jobs.codex ]'
check "Init_NoHostMaps_CodexReadsTheSamePair" '[ "$(project_jobs_pair codex)" = "$codex_before" ]'
check "Init_NoHostMaps_OldModelGoes" '! project_keys jobs | grep -qx model'
check "Init_NoHostMaps_OldEffortGoes" '! project_keys jobs | grep -qx effort'
check "Init_NoHostMaps_ReportHasALineForClaudesModel" '[ -n "$(change_line_to jobs.model jobs.claude.model)" ]'
check "Init_NoHostMaps_ReportHasALineForCodexsModel" '[ -n "$(change_line_to jobs.model jobs.codex.model)" ]'
for roster_name in Sonnet Opus Fable Haiku; do
  roster_model="$(printf '%s' "$roster_name" | tr '[:upper:]' '[:lower:]')"
  new_project "jobs-$roster_model" "${config_body}jobs:\n  model: $roster_model\n"
  codex_before="$(project_jobs_pair codex)"
  run_init >/dev/null 2>&1
  check "Init_NoHostMapsOldModel${roster_name}_CodexReadsItsOwnMap" '[ "$(project_jobs_from codex)" = jobs.codex ]'
  check "Init_NoHostMapsOldModel${roster_name}_CodexGetsTheMappedModel" '[ "$(project_jobs_pair codex)" = "$codex_before" ]'
done
new_project jobs-claude-map "${config_body}jobs:\n  model: $model_written\n  effort: $effort_written\n  claude:\n    model: claude-own\n"
claude_before="$(project_jobs_pair claude)"; codex_before="$(project_jobs_pair codex)"
run_init >/dev/null 2>&1
check "Init_ClaudeMapOnly_CodexReadsItsOwnMap" '[ "$(project_jobs_from codex)" = jobs.codex ]'
check "Init_ClaudeMapOnly_CodexReadsTheSamePair" '[ "$(project_jobs_pair codex)" = "$codex_before" ]'
check "Init_ClaudeMapOnly_ClaudeReadsTheSamePair" '[ "$(project_jobs_pair claude)" = "$claude_before" ]'
check "Init_ClaudeMapOnly_ReportHasNoLineForClaude" '[ -z "$(change_line_to jobs.model jobs.claude.model)$(change_line_to jobs.effort jobs.claude.effort)" ]'
new_project jobs-both-maps "${config_body}jobs:\n  model: $model_written\n  effort: $effort_written\n  claude:\n    model: claude-own\n  codex:\n    effort: low\n"
claude_before="$(project_jobs_pair claude)"; codex_before="$(project_jobs_pair codex)"
run_init >/dev/null 2>&1
check "Init_BothHostMaps_OldModelGoes" '! project_keys jobs | grep -qx model'
check "Init_BothHostMaps_OldEffortGoes" '! project_keys jobs | grep -qx effort'
check "Init_BothHostMaps_ClaudeReadsTheSamePair" '[ "$(project_jobs_pair claude)" = "$claude_before" ]'
check "Init_BothHostMaps_CodexReadsTheSamePair" '[ "$(project_jobs_pair codex)" = "$codex_before" ]'
check "Init_BothHostMaps_ReportLineMovesTheOldModelNowhere" '[ "$(change_line jobs.model | cut -f2)" = - ]'
new_project jobs-only-model "${config_body}jobs:\n  model: $model_written\n"
run_init >/dev/null 2>&1
check "Init_OnlyOldModel_ClaudeReadsItsOwnMap" '[ "$(project_jobs_from claude)" = jobs.claude ]'
check "Init_OnlyOldModel_NoClaudeEffortKeyIsWritten" '! project_keys jobs.claude | grep -qx effort'
check "Init_OnlyOldModel_NoCodexEffortKeyIsWritten" '! project_keys jobs.codex | grep -qx effort'
new_project jobs-quoted "${config_body}jobs:\n  model: \"$model_written\"\n"
codex_before="$(project_jobs_pair codex)"
run_init >/dev/null 2>&1
check "Init_QuotedOldModel_KeepsItsQuotesInBothMaps" '[ "$(grep -c "^    model: \".*\"\$" .flow/config.yaml)" = 2 ]'
check "Init_QuotedOldModel_CodexGetsTheMappedModel" '[ "$(project_jobs_pair codex)" = "$codex_before" ]'
new_project jobs-commented "${config_body}jobs:\n  model: $model_written  # the roster default\n"
run_init >/dev/null 2>&1
check "Init_OldModelWithTrailingComment_CommentOnEveryTarget" '[ "$(grep -c "^    model: .*  # the roster default\$" .flow/config.yaml)" = 2 ]'
new_project jobs-codex-max "${config_body}jobs:\n  host: codex\n  model: $model_written\n  effort: max\n"
run_init > "$work/jobs-codex-max.out" 2>&1
check "Init_OldEffortMaxOnACodexProject_GapNamesTheMigratedLine" 'grep -qF ".flow/config.yaml:$(project_line jobs.codex.effort): jobs.codex.effort is max;" "$work/jobs-codex-max.out"'

[ "$fails" -eq 0 ] && { echo "config-migration: ok"; exit 0; }
echo "config-migration: $fails failed"; exit 1
