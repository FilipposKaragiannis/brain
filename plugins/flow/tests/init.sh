#!/bin/sh
# init.sh: init: the worktree hooks in local settings, the pool worktrees' plugin pins at session
# start, a long pool and the Slack webhook, nothing of flow tracked, Codex, a repo that committed
# flow before, a linked worktree, and worktree_name.
# Takes no argument. Exit 0 when every check passes, 1 on any failure.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
P="$(cd "$here/.." && pwd)"; export FLOW_PLUGIN="$P"
work="$(mktemp -d)"
. "$P/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$P"
trap 'sandbox_close $?' EXIT
. "$here/_flow_setup.sh"
. "$here/_claimed_worktree_fixture.sh"
. "$here/_init_fixture.sh"
FLOW_PLUGIN="$plugin_copy" "$init" >/dev/null 2>&1
echo "init: the Claude worktree hooks in this user's local settings"
mkdir -p .claude && printf '{}\n' > .claude/settings.json && printf '{"permissions":{"allow":["Bash(ls)"]}}\n' > .claude/settings.local.json
FLOW_PLUGIN="$plugin_copy" "$init" --check > "$work/hooks-check.out" 2>&1; code=$?
check "InitCheck_LocalSettingsWithoutTheEntries_ReportedAsDrift" sh -c "[ $code = 1 ] && grep -q 'drift: .claude/settings.local.json: the flow WorktreeCreate and WorktreeRemove entries are missing' '$work/hooks-check.out'"
check "SessionStart_LocalSettingsWithoutTheEntries_NamesThem" sh -c "echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start' | grep -q 'settings.local.json has no flow worktree hooks'"
FLOW_PLUGIN="$plugin_copy" "$init" >/dev/null 2>&1
check_all "Init_LocalSettingsWithOtherKeys_KeepsThemBesideTheEntries" '[ "$(jget permissions.allow.0 < .claude/settings.local.json)" = "Bash(ls)" ] && jget hooks.WorktreeRemove.0.hooks.0.command < .claude/settings.local.json | grep -qF "/.flow/hooks/worktree-remove.sh"'
check "InitCheck_CommittedSettingsWithoutFlowHooksAndLocalEntries_UpToDate" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'up to date'"
check "SessionStart_LocalSettingsWithTheEntries_Silent" sh -c "[ -z \"\$(echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start')\" ]"
sed -i.bak 's|/.flow/hooks/worktree-create.sh|/.flow/hooks/worktree-create.sh --old|' .claude/settings.local.json && rm -f .claude/settings.local.json.bak
check "InitCheck_ChangedEntry_ReportedAsDrift" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'drift: .claude/settings.local.json: the flow WorktreeCreate and WorktreeRemove entries are missing or changed'"
FLOW_PLUGIN="$plugin_copy" "$init" >/dev/null 2>&1
check_all "Init_ChangedEntry_ReplacedByTheCurrentOne" '! grep -q -- "--old" .claude/settings.local.json && [ "$(jget hooks.WorktreeCreate < .claude/settings.local.json | grep -o "worktree-create.sh" | wc -l | tr -d " ")" = 1 ]'
printf '{"hooks":{"WorktreeCreate":[{"hooks":[{"type":"command","command":".flow/hooks/worktree-create.sh"}]}],"WorktreeRemove":[{"hooks":[{"type":"command","command":".flow/hooks/worktree-remove.sh"}]}]}}\n' > .claude/settings.json && cp .claude/settings.json "$work/committed-settings.json"
FLOW_PLUGIN="$plugin_copy" "$init" --check > "$work/hooks-check.out" 2>&1; code=$?
check "InitCheck_CommittedSettingsWithAFlowHook_NotesItWithTheEntry" sh -c "grep -q 'note: .claude/settings.json still carries flow worktree hooks; remove them' '$work/hooks-check.out' && grep -qF '\"command\": \".flow/hooks/worktree-remove.sh\"' '$work/hooks-check.out'"
check "InitCheck_CommittedSettingsWithAFlowHook_StillPasses" [ "$code" = 0 ]
FLOW_PLUGIN="$plugin_copy" "$init" > "$work/hooks-init.out" 2>&1
check "Init_CommittedSettingsWithAFlowHook_NextSaysToRemoveItWithTheEntry" sh -c "sed -n '/^Next:/,\$p' '$work/hooks-init.out' | grep -q 'remove the flow worktree hooks from .claude/settings.json' && sed -n '/^Next:/,\$p' '$work/hooks-init.out' | grep -qF '\"command\": \".flow/hooks/worktree-create.sh\"'"
check "Init_CommittedSettingsWithAFlowHook_LeavesThatFileAsItIs" cmp -s .claude/settings.json "$work/committed-settings.json"
printf '{"hooks":' > .claude/settings.local.json
FLOW_PLUGIN="$plugin_copy" "$init" > "$work/hooks-init.out" 2>&1; code=$?
check "Init_LocalSettingsNotJson_RefusedWithTheFileAndLeftAsItIs" sh -c "[ $code = 1 ] && grep -q 'refused: .claude/settings.local.json is not valid JSON' '$work/hooks-init.out' && [ \"\$(cat .claude/settings.local.json)\" = '{\"hooks\":' ]"
printf '{"hooks":{"WorktreeRemove":[{"hooks":[{"type":"command","command":".flow/hooks/worktree-remove.sh","timeout":30},{"type":"command","command":"./scripts/cleanup-session.sh"}]}]}}\n' > .claude/settings.local.json
FLOW_PLUGIN="$plugin_copy" "$init" >/dev/null 2>&1
check_all "Init_MixedGroupWithAFlowHook_KeepsTheUnrelatedCommand" '[ "$(jget hooks.WorktreeRemove.0.hooks.1.command < .claude/settings.local.json)" = ./scripts/cleanup-session.sh ]'
check_all "Init_MixedGroupWithAFlowHook_FlowCommandIsTheNewOne" '[ "$(jget hooks.WorktreeRemove < .claude/settings.local.json | grep -o "worktree-remove.sh" | wc -l | tr -d " ")" = 1 ] && jget hooks.WorktreeRemove.0.hooks.0.command < .claude/settings.local.json | grep -qF "worktree list --porcelain"'
rm -rf .claude
echo "session-start: the pool worktrees' plugin pins"
git worktree add -q --detach ../plugin-wt
cfg="$work/claude-config"; mkdir -p "$cfg/plugins/cache/m/flow/1.0.0" "$cfg/plugins/cache/m/flow/2.0.0" "$cfg/plugins/cache/m/other/1.0.0"
registry="$cfg/plugins/installed_plugins.json"
write_registry() { # write_registry <worktree version> <user version> <user install dir>
  python3 -c 'import json, sys
wt, user, user_dir, cache, repo, registry = sys.argv[1:]
flow = [{"scope": "user", "installPath": user_dir, "version": user, "gitCommitSha": "new"},
        {"scope": "project", "projectPath": repo + "/../plugin-wt", "installPath": cache + "/flow/1.0.0", "version": wt, "gitCommitSha": "old"},
        {"scope": "project", "projectPath": "/elsewhere/repo", "installPath": cache + "/flow/1.0.0", "version": "1.0.0", "gitCommitSha": "old"}]
other = [{"scope": "project", "projectPath": repo + "/../plugin-wt", "installPath": cache + "/other/1.0.0", "version": "1.0.0"}]
json.dump({"version": 2, "plugins": {"flow@m": flow, "other@m": other}}, open(registry, "w"), indent=2)' "$1" "$2" "$3" "$cfg/plugins/cache/m" "$repo" "$registry"
}
write_registry 1.0.0 2.0.0 "$cfg/plugins/cache/m/flow/2.0.0"
sync_out="$(echo '{}' | CLAUDE_CONFIG_DIR="$cfg" FLOW_PLUGIN="$plugin_copy" "$start")"
check "SessionStart_WorktreePinBehindTheNewestInstalled_Lifted" [ "$(jget plugins.flow@m.1.version < "$registry")" = "2.0.0" ]
check_all "SessionStart_LiftedPin_TakesTheNewestInstallPathAndCommit" '[ "$(jget plugins.flow@m.1.installPath < "$registry")" = "$cfg/plugins/cache/m/flow/2.0.0" ] && [ "$(jget plugins.flow@m.1.gitCommitSha < "$registry")" = new ]'
check "SessionStart_LiftedPin_SaysWhichPinItLifted" sh -c "printf '%s' '$sync_out' | grep -q 'plugin pin lifted: flow@m in plugin-wt: 1.0.0 -> 2.0.0'"
check "SessionStart_RecordOfAnotherRepository_LeftAlone" [ "$(jget plugins.flow@m.2.version < "$registry")" = "1.0.0" ]
check "SessionStart_PluginWithOneVersion_NothingToLift" [ "$(jget plugins.other@m.0.version < "$registry")" = "1.0.0" ]
cp "$registry" "$registry.before"
check "SessionStart_NothingBehind_SilentAndRegistryUntouched" sh -c "[ -z \"\$(echo '{}' | CLAUDE_CONFIG_DIR='$cfg' FLOW_PLUGIN='$plugin_copy' '$start')\" ] && cmp -s '$registry' '$registry.before'"
write_registry 1.0.0 3.0.0 "$cfg/plugins/cache/m/flow/3.0.0-missing"
echo '{}' | CLAUDE_CONFIG_DIR="$cfg" FLOW_PLUGIN="$plugin_copy" "$start" >/dev/null
check "SessionStart_NewerVersionMissingFromTheCache_NotATarget" [ "$(jget plugins.flow@m.1.version < "$registry")" = "1.0.0" ]
check "SessionStart_NoRegistry_Silent" sh -c "[ -z \"\$(echo '{}' | CLAUDE_CONFIG_DIR='$work/no-such-config' FLOW_PLUGIN='$plugin_copy' '$start')\" ]"
write_registry 1.0.0 2.0.0 "$cfg/plugins/cache/m/flow/2.0.0"
python3 -c 'import fcntl, sys, time
lock = open(sys.argv[1] + ".lock", "w"); fcntl.flock(lock, fcntl.LOCK_EX); time.sleep(2)' "$registry" &
holder=$!; sleep 0.5
started="$(date +%s)"
echo '{}' | CLAUDE_CONFIG_DIR="$cfg" FLOW_PLUGIN="$plugin_copy" "$start" >/dev/null
waited=$(( $(date +%s) - started ))
wait "$holder"
check_all "SessionStart_SyncInFlight_NextOneWaitsThenLifts" '[ "$waited" -ge 1 ] && [ "$(jget plugins.flow@m.1.version < "$registry")" = "2.0.0" ]'
check "SessionStart_AfterALift_NoTemporaryFileLeft" sh -c "! ls '$cfg/plugins/' | grep -q '\\.tmp$'"
mkdir -p "$cfg/plugins/cache/m/flow/2.0.0-rc.1" "$cfg/plugins/cache/m/flow/2.0.3-beta2"
write_registry 2.0.0 2.0.0-rc.1 "$cfg/plugins/cache/m/flow/2.0.0-rc.1"
echo '{}' | CLAUDE_CONFIG_DIR="$cfg" FLOW_PLUGIN="$plugin_copy" "$start" >/dev/null
check "SessionStart_PrereleaseOfTheSameRelease_DoesNotReplaceIt" [ "$(jget plugins.flow@m.1.version < "$registry")" = "2.0.0" ]
write_registry 2.0.0 2.0.3-beta2 "$cfg/plugins/cache/m/flow/2.0.3-beta2"
echo '{}' | CLAUDE_CONFIG_DIR="$cfg" FLOW_PLUGIN="$plugin_copy" "$start" >/dev/null
check "SessionStart_NewerPrerelease_LiftsAnOlderRelease" [ "$(jget plugins.flow@m.1.version < "$registry")" = "2.0.3-beta2" ]
write_registry 2.0.3-beta2 2.0.9 "$cfg/plugins/cache/m/flow/2.0.0"
echo '{}' | CLAUDE_CONFIG_DIR="$cfg" FLOW_PLUGIN="$plugin_copy" "$start" >/dev/null
check "SessionStart_DigitsInAPrereleaseTag_DoNotOutrankARelease" [ "$(jget plugins.flow@m.1.version < "$registry")" = "2.0.9" ]
write_registry 1.0.0 main "$cfg/plugins/cache/m/flow/2.0.0"
echo '{}' | CLAUDE_CONFIG_DIR="$cfg" FLOW_PLUGIN="$plugin_copy" "$start" >/dev/null
check "SessionStart_VersionNotSemantic_NeverATarget" [ "$(jget plugins.flow@m.1.version < "$registry")" = "1.0.0" ]
git worktree remove --force ../plugin-wt
rm .flow/stamp
check "session-start: no stamp asks for one init" sh -c "echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start' | grep -q 'no install stamp'"
printf 'adapters:\n  default: local\nbase: main\npool:\npool_max: 0\n' > .flow/config.yaml
check "init: --check flags an empty pool with pool_max 0 as a gap" sh -c "! FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'up to date' && FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'gap: .flow/config.yaml: the pool is empty'"
check "init: lists the gap after an install" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' | grep -q 'Gaps'"
write_command_config() { printf 'adapters:\n  default: local\nbase: main\npool:\npool_max: 1\n%b' "$1" > .flow/config.yaml; }
write_command_config 'worktree_create: workspace new --from {base}\n'
FLOW_PLUGIN="$plugin_copy" "$init" --check > "$work/init-create.out" 2>&1; code=$?
check "InitCheckOfCreateCommandWithoutPath_NamesGap: --check names a worktree_create without {path} as a gap" grep -qF 'gap: .flow/config.yaml: worktree_create has no {path}' "$work/init-create.out"
check "InitCheckOfCreateCommandWithoutPath_ExitsNonZero: --check exits non-zero on a worktree_create without {path}" [ "$code" != 0 ]
write_command_config 'worktree_remove: workspace remove\n'
FLOW_PLUGIN="$plugin_copy" "$init" --check > "$work/init-remove.out" 2>&1; code=$?
check "InitCheckOfRemoveCommandWithoutPath_NamesGap: --check names a worktree_remove without {path} as a gap" grep -qF 'gap: .flow/config.yaml: worktree_remove has no {path}' "$work/init-remove.out"
check "InitCheckOfRemoveCommandWithoutPath_ExitsNonZero: --check exits non-zero on a worktree_remove without {path}" [ "$code" != 0 ]
write_command_config 'worktree_create: workspace new "{path}" --from {base}\n'
FLOW_PLUGIN="$plugin_copy" "$init" --check > "$work/init-quoted.out" 2>&1
check "InitCheckOfCreateCommandQuotingPath_NamesGap: --check names a worktree_create with {path} inside quotes as a gap" grep -qF 'gap: .flow/config.yaml: worktree_create quotes {path}' "$work/init-quoted.out"
write_command_config "worktree_create: workspace new '{path}' --from {base}\n"
FLOW_PLUGIN="$plugin_copy" "$init" --check > "$work/init-single-quoted.out" 2>&1
check "InitCheckOfCreateCommandSingleQuotingPath_NamesGap: --check names a worktree_create with {path} inside single quotes as a gap" grep -qF 'gap: .flow/config.yaml: worktree_create quotes {path}' "$work/init-single-quoted.out"
write_command_config 'worktree_remove: workspace remove "{path}"\n'
FLOW_PLUGIN="$plugin_copy" "$init" --check > "$work/init-remove-quoted.out" 2>&1
check "InitCheckOfRemoveCommandQuotingPath_NamesGap: --check names a worktree_remove with {path} inside quotes as a gap" grep -qF 'gap: .flow/config.yaml: worktree_remove quotes {path}' "$work/init-remove-quoted.out"
write_command_config 'worktree_create: workspace new \\{path} --from {base}\n'
FLOW_PLUGIN="$plugin_copy" "$init" --check > "$work/init-escaped.out" 2>&1
check "InitCheckOfCreateCommandEscapingPath_NamesGap: --check names a worktree_create with {path} after a backslash as a gap" grep -qF 'gap: .flow/config.yaml: worktree_create quotes {path}' "$work/init-escaped.out"
write_command_config 'worktree_create: workspace new "$(dirname "{path}")" --from {base}\n'
FLOW_PLUGIN="$plugin_copy" "$init" --check > "$work/init-substituted.out" 2>&1
check "InitCheckOfCreateCommandQuotingPathInQuotedSubstitution_NamesGap: --check names a worktree_create with {path} quoted inside a quoted \$(...) as a gap" grep -qF 'gap: .flow/config.yaml: worktree_create quotes {path}' "$work/init-substituted.out"
write_command_config 'worktree_create: workspace new `basename {path}` --from {base}\n'
FLOW_PLUGIN="$plugin_copy" "$init" --check > "$work/init-backticked.out" 2>&1
check "InitCheckOfCreateCommandWithPathInBackticks_NamesGap: --check names a worktree_create with {path} inside backticks as a gap" grep -qF 'gap: .flow/config.yaml: worktree_create has {path} inside backticks' "$work/init-backticked.out"
write_command_config 'worktree_create: workspace new {path} --from {base}\nworktree_remove: workspace remove {path}\n'
check "InitCheckOfCommandsHoldingPath_IsClean: --check is clean with a worktree_create and a worktree_remove that hold {path}" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'up to date'"
mkdir -p "$work/plain" && cd "$work/plain" && git init -q
check "session-start: silent in a project without the flow" sh -c "[ -z \"\$(echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start')\" ]"

echo "init: a long pool, and the Slack webhook from the environment"
mkdir -p "$work/bigpool" && cd "$work/bigpool" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init
for n in 1 2 3 4 5; do git worktree add -q "../app-wt-$n" -b "wt$n" >/dev/null 2>&1; done
out="$(FLOW_PLUGIN="$plugin_copy" "$init" 2>&1)"
check "init: more worktrees than three raise pool_max to match" sh -c "grep -qx 'pool_max: 5' .flow/config.yaml && [ \"\$(grep -c '^  - ../app-wt-' .flow/config.yaml)\" = 5 ]"
check "init: says every listed worktree becomes a task slot" sh -c 'printf "%s" "$1" | grep -q "5 worktrees already exist"' _ "$out"
. "$here/_fake_curl_fixture.sh"
printf 'adapters:\n  default: local\nbase: main\npool_max: 1\nnotify:\n  desktop: false\n  slack_webhook: https://config.example/hook\n' > .flow/config.yaml
: > "$work/curl.log"
PATH="$work/fakebin:$PATH" "$P/scripts/notify.sh" merge local:task/1 "ready" >/dev/null 2>&1
check "notify: the config webhook is the fallback" sh -c "grep -q 'config.example/hook' '$work/curl.log'"
: > "$work/curl.log"
PATH="$work/fakebin:$PATH" FLOW_SLACK_WEBHOOK=https://env.example/hook "$P/scripts/notify.sh" merge local:task/1 "ready" >/dev/null 2>&1
check "notify: FLOW_SLACK_WEBHOOK wins over the config" sh -c "grep -q 'env.example/hook' '$work/curl.log' && ! grep -q 'config.example' '$work/curl.log'"
printf 'adapters:\n  default: local\nbase: main\npool_max: 1\nnotify:\n  desktop: false\n' > .flow/config.yaml
: > "$work/curl.log"
PATH="$work/fakebin:$PATH" FLOW_SLACK_WEBHOOK=https://env.example/hook "$P/scripts/notify.sh" merge local:task/1 "ready" >/dev/null 2>&1
check "notify: the variable alone is enough, with no URL in the config" sh -c "grep -q 'env.example/hook' '$work/curl.log'"

echo "init: nothing of flow is tracked"
mkdir -p "$work/notrace" && cd "$work/notrace" && git init -q -b main origin-src && (cd origin-src && git config user.email t@t && git config user.name t && printf 'hi\n' > README.md && git add -A && git commit -qm init)
git clone -q origin-src app 2>/dev/null && cd app && git config user.email t@t && git config user.name t
ntmain="$PWD"
FLOW_PLUGIN="$plugin_copy" "$init" > "$work/notrace.out" 2>&1
check "Init_FreshClone_GitStatusCleanAndNothingTracked" sh -c "[ -f .flow/config.yaml ] && [ -z \"\$(git status --porcelain --untracked-files=all)\" ] && [ -z \"\$(git ls-files .flow)\" ]"
check "Init_FreshClone_TheExcludeBlockCoversAllOfFlow" sh -c "awk '/^# flow:begin/{on=1; next} /^# flow:end/{on=0} on' .git/info/exclude | grep -qxF '.flow/' && [ ! -e .gitignore ]"
check "Init_Next_NoLongerSaysToCommitFlow" sh -c "! grep -q 'commit .flow' '$work/notrace.out' && grep -q 'nothing under .flow/ is committed' '$work/notrace.out'"
check "Init_RepoWithoutCodex_CodexFilesInTheUserHomeAndSaidSo" sh -c "[ -f '$HOME/.codex/rules/flow.rules' ] && [ -f '$HOME/.codex/agents/explorer.toml' ] && [ ! -e .codex ] && grep -qF 'Codex rules and agents: $HOME/.codex (the repository has no .codex folder)' '$work/notrace.out'"
create_command="$(jget hooks.WorktreeCreate.0.hooks.0.command < .claude/settings.local.json)"; remove_command="$(jget hooks.WorktreeRemove.0.hooks.0.command < .claude/settings.local.json)"
check_all "Init_RepoWithoutClaudeFolder_WritesBothEntriesToTheLocalSettings" 'case "$create_command" in *"/.flow/hooks/worktree-create.sh"*) ;; *) false ;; esac && case "$remove_command" in *"/.flow/hooks/worktree-remove.sh"*) ;; *) false ;; esac'
check "Init_RepoWithoutClaudeFolder_LocalSettingsIgnoredByTheExclude" git check-ignore -q .claude/settings.local.json
check "Init_RepoWithoutClaudeFolder_NoSharedSettingsWritten" [ ! -e .claude/settings.json ]
# The entries init wrote, run as Claude runs them, in a clone with flow and in one without.
jget hooks.WorktreeCreate.0.hooks.0.command < .claude/settings.local.json > "$work/hook-create.sh"
jget hooks.WorktreeRemove.0.hooks.0.command < .claude/settings.local.json > "$work/hook-remove.sh"
printf 'adapters:\n  default: local\nbase: main\npool:\npool_max: 1\nworktree_copy:\n  - local.env\nworktree_setup:\n  - printf ran > setup.txt\nnotify:\n  desktop: false\n' > .flow/config.yaml
printf 'secret\n' > local.env && printf 'local.env\n' >> .git/info/exclude
ntpath="$(printf '{"name":"bold-oak","cwd":"%s"}' "$ntmain" | CLAUDE_PROJECT_DIR="$ntmain" FLOW_PLUGIN="$plugin_copy" sh "$work/hook-create.sh" 2>/dev/null | tail -n 1)"
check "WorktreeCreateHook_FlowInstalled_ClaimsAGrownPoolWorktree" sh -c "[ '$ntpath' = \"\$(cd ../app-wt-1 2>/dev/null && pwd -P)\" ] && grep -q 'adhoc:bold-oak' '$ntpath/.flow/claim.json'"
check "LinkedWorktree_FlowHome_ResolvesToTheMainWorktree" sh -c "cd '$ntpath' && [ \"\$(. '$plugin_copy/lib/flow.sh'; flow_home)\" = \"\$(cd '$ntmain' && pwd -P)/.flow\" ] && [ ! -e .flow/config.yaml ]"
check "LinkedWorktree_ClaimFile_IgnoredByTheSharedExclude" sh -c "[ -f '$ntpath/.flow/claim.json' ] && git -C '$ntpath' check-ignore -q .flow/claim.json && [ -z \"\$(git -C '$ntpath' status --porcelain --untracked-files=all -- .flow)\" ]"
check "LinkedWorktree_Grown_WorktreeCopyAndWorktreeSetupRan" sh -c "[ \"\$(cat '$ntpath/local.env')\" = secret ] && [ \"\$(cat '$ntpath/setup.txt')\" = ran ]"
check "SessionStart_LinkedWorktree_ReadsTheMainWorktreesStamp" sh -c "cd '$ntpath' && [ -z \"\$(echo '{}' | FLOW_PLUGIN='$plugin_copy' '$start')\" ]"
# A linked worktree has no .flow/hooks of its own, so only the main worktree's wrapper can answer.
printf '{"cwd":"%s"}' "$ntpath" | CLAUDE_PROJECT_DIR="$ntpath" FLOW_PLUGIN="$plugin_copy" sh "$work/hook-remove.sh" > "$work/hook-remove.out" 2>&1; code=$?
check "WorktreeRemoveHook_RunFromALinkedWorktree_RunsTheMainWorktreesWrapper" sh -c "[ $code = 0 ] && [ ! -s '$work/hook-remove.out' ]"
git clone -q "$work/notrace/origin-src" "$work/notrace/teammate" 2>/dev/null
tmate="$work/notrace/teammate"
printf '{"name":"calm-fern","cwd":"%s"}' "$tmate" | CLAUDE_PROJECT_DIR="$tmate" sh "$work/hook-create.sh" > "$work/hook-create.out" 2> "$work/hook-create.err"; code=$?
check "WorktreeCreateHook_CloneWithoutFlow_FailsAndMakesNoWorktree" sh -c "[ $code != 0 ] && [ ! -s '$work/hook-create.out' ] && [ ! -e '$tmate/.claude' ] && [ \"\$(git -C '$tmate' worktree list | wc -l | tr -d ' ')\" = 1 ]"

echo "init: Codex in the repository or the user home"
mkdir -p "$work/codexrepo" && cd "$work/codexrepo" && git init -q -b main && git config user.email t@t && git config user.name t && mkdir .codex && printf '[plugins]\n' > .codex/config.toml && git add -A && git commit -qm init
FLOW_PLUGIN="$plugin_copy" "$init" > "$work/codexrepo.out" 2>&1
check "Init_RepoWithCodex_CodexFilesInTheRepoAndSaidSo" sh -c "[ -f .codex/rules/flow.rules ] && [ -f .codex/agents/explorer.toml ] && grep -qF 'Codex rules and agents: .codex (the repository has a .codex folder)' '$work/codexrepo.out' && grep -q 'commit .codex/' '$work/codexrepo.out'"
mkdir -p "$work/codexuser" && cd "$work/codexuser" && git init -q -b main && git config user.email t@t && git config user.name t && mkdir .codex && printf '[plugins]\n' > .codex/config.toml && git add -A && git commit -qm init
CODEX_HOME="$work/codex-home" FLOW_PLUGIN="$plugin_copy" "$init" --user-codex > "$work/codexuser.out" 2>&1
check "Init_UserCodex_CodexFilesInCodexHomeAndTheRepoUntouched" sh -c "[ -f '$work/codex-home/rules/flow.rules' ] && [ ! -e .codex/rules ] && grep -qF 'Codex rules and agents: $work/codex-home (--user-codex)' '$work/codexuser.out' && [ -z \"\$(git status --porcelain --untracked-files=all)\" ]"
check "InitCheck_AfterUserCodex_KeepsTheUserHomeWithoutTheFlag" sh -c "CODEX_HOME='$work/codex-home' FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'up to date'"
# Two repositories that share one Codex home, which has a space in its name.
shared="$work/shared codex"
mkdir -p "$work/share-a" "$work/share-b" && for r in share-a share-b; do (cd "$work/$r" && git init -q -b main && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init); done
cd "$work/share-a" && CODEX_HOME="$shared" FLOW_PLUGIN="$plugin_copy" "$init" >/dev/null 2>&1
check "Init_CodexHomeWithASpace_StampHoldsTheWholePath" sh -c "grep -qF '	$shared/agents/explorer.toml' .flow/stamp && grep -qF '	$shared/agents/explorer.toml' '$shared/.flow-stamp'"
printf '# mine\n' >> "$shared/agents/explorer.toml"
check "InitCheck_CodexHomeWithASpace_NamesAHandEdit" sh -c "CODEX_HOME='$shared' FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -qF 'edited by hand: $shared/agents/explorer.toml'"
cd "$work/share-b" && CODEX_HOME="$shared" FLOW_PLUGIN="$plugin_copy" "$init" > "$work/share-b.out" 2>&1; code=$?
check "Init_SecondRepoOnASharedCodexHome_RefusesAHandEditAndSaysSo" sh -c "[ $code = 1 ] && grep -q '# mine' '$shared/agents/explorer.toml' && grep -qF 'refused: $shared/agents/explorer.toml was edited by hand' '$work/share-b.out'"
check "Init_SecondRepoOnASharedCodexHome_ForceReplacesTheEdit" sh -c "CODEX_HOME='$shared' FLOW_PLUGIN='$plugin_copy' '$init' --force >/dev/null 2>&1 && ! grep -q '# mine' '$shared/agents/explorer.toml' && cd '$work/share-a' && CODEX_HOME='$shared' FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'up to date'"
mkdir -p "$work/foreign codex/agents" && printf 'mine\n' > "$work/foreign codex/agents/planner.toml"
cd "$work/share-b" && CODEX_HOME="$work/foreign codex" FLOW_PLUGIN="$plugin_copy" "$init" --user-codex > "$work/foreign.out" 2>&1; code=$?
check "Init_UserCodexFileFlowNeverWrote_RefusedAndKept" sh -c "[ $code = 1 ] && [ \"\$(cat '$work/foreign codex/agents/planner.toml')\" = mine ] && grep -q 'does not record flow writing it' '$work/foreign.out'"

echo "init: a repo that committed flow before"
mkdir -p "$work/migrate" && cd "$work/migrate" && git init -q -b main && git config user.email t@t && git config user.name t
mkdir .flow && printf 'adapters:\n  default: local\nbase: main\npool:\npool_max: 1\n' > .flow/config.yaml && printf 'source\tx\n' > .flow/stamp
printf 'node_modules/\n# flow:begin (written by flow:init; state that stays on this machine)\n.flow/items/\n.flow/*.lock/\n.flow/claim.json\n# flow:end\n' > .gitignore
git add -A && git commit -qm init
FLOW_PLUGIN="$plugin_copy" "$init" > "$work/migrate.out" 2>&1
check "Init_GitignoreBlockInitWrote_RemovedAndTheOwnersLinesKept" sh -c "[ \"\$(cat .gitignore)\" = node_modules/ ] && grep -qxF '.flow/' .git/info/exclude"
check "Init_FlowTrackedBefore_PrintsTheGitRmCachedCommand" sh -c "grep -qF 'git rm -r --cached --quiet -- .flow' '$work/migrate.out' && grep -q 'git still tracks 2 files under .flow/' '$work/migrate.out'"
check "Init_FlowTrackedBefore_NeverRunsTheGitRm" [ "$(git ls-files .flow | wc -l | tr -d ' ')" = 2 ]
git rm -r -q --cached -- .flow && git commit -qam untrack
check "Init_AfterTheOwnersGitRm_StatusClean" sh -c "[ -z \"\$(git status --porcelain --untracked-files=all)\" ] && [ -f .flow/config.yaml ]"
printf '# flow:begin (written by flow:init; state that stays on this machine)\n.flow/items/\n.flow/mine.txt\n# flow:end\n' > .gitignore
FLOW_PLUGIN="$plugin_copy" "$init" > "$work/migrate.out" 2>&1
check "Init_GitignoreBlockEditedByHand_LeftAndReported" sh -c "grep -qxF '.flow/mine.txt' .gitignore && grep -q 'edited by hand (it also lists .flow/mine.txt)' '$work/migrate.out'"

echo "init: from a linked worktree, and the pool it proposes"
mkdir -p "$work/linked" && cd "$work/linked" && git init -q -b main app && cd app && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init
git worktree add -q --detach ../app-wt-1 && git worktree add -q --detach .claude/worktrees/bold-oak && git worktree add -q --detach "$work/outside-wt"
lmain="$PWD"; cd ../app-wt-1
out="$(FLOW_PLUGIN="$plugin_copy" "$init" 2>&1)"
check "init: from a linked worktree it writes the main worktree's config" sh -c "[ -f '$lmain/.flow/config.yaml' ] && [ ! -e .flow/config.yaml ]"
check "init: from a linked worktree it says it works on the main worktree's flow home" sh -c 'printf "%s" "$1" | grep -q "linked worktree; init works on the flow home in the main worktree"' _ "$out"
check "init: --check from a linked worktree reads the main worktree's config" sh -c "FLOW_PLUGIN='$plugin_copy' '$init' --check | grep -q 'up to date'"
check "init: the pool proposal keeps a worktree beside the main one" sh -c "[ \"\$(. '$P/lib/flow.sh'; yaml_get '$lmain/.flow/config.yaml' pool)\" = ../app-wt-1 ]"
check "init: the pool proposal skips Claude's session worktrees" sh -c "! grep -q 'bold-oak' '$lmain/.flow/config.yaml'"
check "init: the pool proposal skips a worktree outside the main worktree's parent folder" sh -c "! grep -q 'outside-wt' '$lmain/.flow/config.yaml'"
mkdir -p "$work/nogit"
FLOW_PLUGIN="$plugin_copy" "$init" --root "$work/nogit" > "$work/nogit.out" 2>&1; code=$?
check "init: with no main worktree to find it refuses and names the problem" sh -c "[ $code = 1 ] && grep -q 'no main worktree for $work/nogit' '$work/nogit.out'"

echo "worktree_name"
mkdir -p "$work/named" && cd "$work/named" && git init -q -b main shop && cd shop && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init
mkdir -p .flow
namedcfg() { printf 'adapters:\n  default: local\nbase: main\npool:\n%bpool_max: 9\n%bnotify:\n  desktop: false\n' "$1" "$2" > .flow/config.yaml; }
namedcfg '' 'worktree_name: ../{repo}-box-{n}\n'
nm1="$("$P/scripts/new.sh" task "Named")"
nw1="$("$P/scripts/steward.sh" claim "$nm1" 2>/dev/null)"
check "worktree_name: a grown worktree takes the template, {repo} and {n} filled" [ "$nw1" = "$(cd ../shop-box-1 2>/dev/null && pwd -P)" ]
mkdir ../shop-box-2
namedcfg '  - ../shop-box-1\n  - ../shop-box-3\n' 'worktree_name: ../{repo}-box-{n}\n'
"$P/scripts/steward.sh" add >/dev/null 2>&1
check "worktree_name: add takes the first number no pool entry and no folder uses" sh -c "[ -d ../shop-box-4 ] && [ \"\$(. '$P/lib/flow.sh'; yaml_get .flow/config.yaml pool | tail -1)\" = ../shop-box-4 ]"
namedcfg '  - ../shop-box-1\n' ''
"$P/scripts/steward.sh" add >/dev/null 2>&1
check "worktree_name: unset, a new worktree keeps today's name" [ -d ../shop-wt-1 ]
namedcfg '  - ../shop-box-1\n' 'worktree_name: ../{repo}-box\n'
"$P/scripts/steward.sh" add > "$work/named.out" 2>&1; code=$?
check "worktree_name: one with no {n} is refused, exit 2, with the reason" sh -c "[ $code = 2 ] && grep -q 'worktree_name ../{repo}-box has no {n}' '$work/named.out'"
check "worktree_name: a refused add creates nothing" sh -c "[ ! -e ../shop-box ] && [ \"\$(. '$P/lib/flow.sh'; yaml_get .flow/config.yaml pool)\" = ../shop-box-1 ]"
nm2="$("$P/scripts/new.sh" task "Named again")"
"$P/scripts/steward.sh" claim "$nm2" > "$work/named.out" 2>&1; code=$?
check "worktree_name: a claim that would grow with one with no {n} says why" grep -q 'worktree_name ../{repo}-box has no {n}' "$work/named.out"
check "worktree_name: a claim refused for no {n} exits 2, a config refusal, not 3 for a full pool" [ "$code" = 2 ]
check "worktree_name: a claim refused for no {n} does not blame pool_max, which is not reached" sh -c "! grep -q pool_max '$work/named.out'"
printf 'adapters:\n  default: local\nbase: main\npool:\n  - ../shop-box-1\npool_max: 1\nworktree_name: ../{repo}-box-{n}\nnotify:\n  desktop: false\n' > .flow/config.yaml
"$P/scripts/steward.sh" claim "$nm2" > "$work/named.out" 2>&1; code=$?
check "worktree_name: a claim with a full pool still exits 3 with the pool_max message, the template unused" sh -c "[ $code = 3 ] && grep -q 'the pool is at pool_max (1)' '$work/named.out'"
namedcfg '  - ../shop-box-1\n' 'worktree_name: ../slots/{n}/checkout\n'
"$P/scripts/steward.sh" add > "$work/named.out" 2>&1; code=$?
check "worktree_name: one whose numbers all give the same idle branch is refused, exit 2, with the reason" sh -c "[ $code = 2 ] && grep -q 'gives every new pool worktree the idle branch main-checkout' '$work/named.out'"
"$P/scripts/steward.sh" claim "$nm2" > "$work/named.out" 2>&1; code=$?
check "worktree_name: a claim refused for a shared idle branch exits 2 with the reason and no pool_max message" sh -c "[ $code = 2 ] && grep -q 'idle branch main-checkout' '$work/named.out' && ! grep -q pool_max '$work/named.out'"
check "worktree_name: a refused add for a shared idle branch creates nothing" sh -c "[ ! -e ../slots ] && [ \"\$(. '$P/lib/flow.sh'; yaml_get .flow/config.yaml pool)\" = ../shop-box-1 ]"
namedcfg '  - ../shop-box-1\n' 'worktree_name: ../slots/checkout-{n}\n'
"$P/scripts/steward.sh" add >/dev/null 2>&1; "$P/scripts/steward.sh" add >/dev/null 2>&1
check "worktree_name: nested folders with {n} in the last name add one worktree per number" sh -c "[ -d ../slots/checkout-1 ] && [ -d ../slots/checkout-2 ]"

[ "$fails" -eq 0 ] && { echo "init: ok"; exit 0; }
echo "init: $fails failed"; exit 1
