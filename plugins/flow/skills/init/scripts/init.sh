#!/bin/sh
# Install or refresh the flow plugin in a repository.
#   init.sh [--root <repo>] [--check] [--force] [--source-hash]
# Writes: .flow/config.yaml (once), .flow/notify.sh, .flow/run-unattended.sh, .flow/jobs/*.sh and
# .flow/hooks/*.sh (wrappers, always replaced), .codex/rules/flow.rules and
# .codex/agents/<flow agents>.toml (replaced, unless edited by hand since: then refused, exit 1,
# --force replaces), a marked block in .gitignore, and .flow/stamp (what it wrote; see stamp.sh).
# --check reports drift and hand edits and writes nothing (exit 1 on either). --source-hash
# prints the hash of the plugin's install set and exits (the session-start hook).
set -u
plugin="$(cd "$(dirname "$0")/../../.." && pwd)"
root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
check=0; force=0; source_hash=0
while [ $# -gt 0 ]; do
  case "$1" in
    --root) root="$2"; shift 2 ;;
    --check) check=1; shift ;;
    --force) force=1; shift ;;
    --source-hash) source_hash=1; shift ;;
    *) echo "init: unknown argument $1" >&2; exit 2 ;;
  esac
done
FLOW_PLUGIN="$plugin"; export FLOW_PLUGIN
. "$plugin/lib/flow.sh"
source_hash() { flow_source_hash "$plugin"; }   # the install set lives in lib/flow.sh
[ "$source_hash" -eq 1 ] && { source_hash; exit 0; }
cd "$root" || exit 2
version="$(json_get "$(cat "$plugin/.claude-plugin/plugin.json")" "version")"
stamp=".flow/stamp"
drift=0; refused=0; changed=""; stamped=""; kept=""
note() { changed="$changed  $1
"; }
drifted() { drift=1; echo "init: drift: $1"; }
gaps=""
gap() { gaps="$gaps  - $1
"; [ "$check" -eq 1 ] && { drift=1; echo "init: gap: $1"; }; }
edited() {
  if [ "$check" -eq 1 ]; then drift=1; echo "init: edited by hand: $1"
  else refused=1; echo "init: refused: $1 was edited by hand since init last wrote it; move the edit to the plugin source, or re-run with --force"; fi
}
die() { echo "init: $1" >&2; exit 1; }
scratch=".flow/.init-tmp"; mkdir -p "$scratch" || die "cannot create $scratch"
trap 'rm -rf "$scratch"' EXIT
install_file() {
  # install_file <built file> <target> [mode] [guard]: replace the target when it differs from
  # the built file. With "guard", refuse when the target also differs from what init last wrote
  # (a hand edit) unless --force; guarded targets land in the stamp. Wrappers and merged files
  # are not guarded: wrappers carry this machine's plugin path, merged files are the owner's.
  if [ -f "$2" ] && cmp -s "$1" "$2"; then [ "${4:-}" = guard ] && stamped="$stamped $2"; return; fi
  if [ "${4:-}" = guard ] && [ -f "$2" ] && [ "$force" -eq 0 ]; then
    last="$(stamp_get "$stamp" "$2")"
    if [ -n "$last" ] && [ "$last" != "$(hash_file "$2")" ]; then edited "$2"; kept="$kept $2"; return; fi
  fi
  if [ "$check" -eq 1 ]; then drifted "$2"; else mkdir -p "$(dirname "$2")" && cp "$1" "$2" && { [ -z "${3:-}" ] || chmod "$3" "$2"; } && note "$2"; fi
  [ "${4:-}" = guard ] && stamped="$stamped $2"
}
write_stamp() {
  tmp="$scratch/stamp"
  {
    printf 'source\t%s\n' "$(source_hash)"
    for t in $stamped; do printf '%s\t%s\n' "$(hash_file "$t")" "$t"; done
    for t in $kept; do printf '%s\t%s\n' "$(stamp_get "$stamp" "$t")" "$t"; done
  } > "$tmp"
  if [ ! -f "$stamp" ] || ! cmp -s "$tmp" "$stamp"; then cp "$tmp" "$stamp" && note "$stamp"; fi
}

main="$(main_worktree)"; [ -n "$main" ] || main="$root"

# 1. Project config, written once.
if [ ! -f .flow/config.yaml ]; then
  if [ "$check" -eq 1 ]; then drifted ".flow/config.yaml is missing"; else
    mkdir -p .flow
    repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
    base="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
    [ -n "$base" ] || base="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
    [ -n "$base" ] || base="main"
    pool="$(git worktree list --porcelain | sed -n 's/^worktree //p' | tail -n +2 | grep -v '/\.flow/tmp/' | while read -r p; do
      python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$p" "$main"; done)"
    {
      echo "# flow configuration. Read by every flow script on both hosts. Keep it flat: key: value,"
      echo "# nested maps, lists as '- item' or [a, b]. No anchors, no multi-line strings."
      echo "adapters:"
      if [ -n "$repo" ]; then echo "  default: github"; echo "  # bug: local    # keep bugs out of GitHub"; else echo "  default: local"; fi
      echo "base: $base"
      echo "# Gates the flow clears itself, by item size. Only plan-approval can be listed. Merge, interview,"
      echo "# feel-test, escalation and ambiguity always wait for you. Use it for items that were grilled and defined."
      echo "auto_gates:"
      echo "  # plan-approval: S,M"
      [ -n "$repo" ] && { echo "github:"; echo "  repo: $repo"; echo "  limit: 100"; }
      echo "# The worktree pool: persistent linked worktrees, one task each. Pool size = parallelism."
      echo "# A claim with no free worktree adds one (named after the last entry, ../$(basename "$main")-wt-<n>)"
      echo "# while the pool is below pool_max, and the steward appends it here. 0 never adds."
      echo "pool:"
      if [ -n "$pool" ]; then printf '%s\n' "$pool" | sed 's/^/  - /'; else echo "  # - ../$(basename "$main")-wt-1"; fi
      pool_n="$(printf '%s\n' "$pool" | grep -c .)"; pool_max=3; [ "$pool_n" -gt 3 ] && pool_max="$pool_n"
      echo "pool_max: $pool_max"
      echo "# Git-ignored files a new worktree gets from the main worktree when it lacks them, and"
      echo "# commands run in a new worktree after that (steward.sh setup <path> re-runs both)."
      echo "worktree_copy:"
      echo "  # - .claude/settings.local.json"
      echo "worktree_setup:"
      echo "  # - dotnet restore"
      echo "# Project gates the verifier runs after build, format and tests: name: command, run from the root."
      echo "# A gate that only matters for some files takes a map: command, and paths (globs; it runs when a"
      echo "# changed file matches one, else the report says it was skipped)."
      echo "gates:"
      echo "  # determinism: ./tools/check-determinism.sh"
      echo "  # harness:"
      echo "  #   command: ./tools/check-harness.sh"
      echo "  #   paths: [server/**, tools/**]"
      echo "# Changed files matching these globs raise the feel-test gate after verify passes."
      echo "feel_test_paths:"
      echo "  # - client/unity/**"
      echo "notify:"
      echo "  desktop: true"
      echo "  idle: false   # true: the scheduled next job says once when it finds nothing ready"
      echo "  # Slack: set FLOW_SLACK_WEBHOOK in the environment of the session or the scheduler (keeps the URL"
      echo "  # out of the repository). A URL here is the fallback; empty with no variable disables Slack."
      echo "  slack_webhook: \"\"   # Slack incoming webhook URL"
      echo "# Scheduled jobs (.flow/jobs/*.sh): the orchestrating session's model and effort, empty for"
      echo "# the host default; the marketplace checkout the weekly retro opens its PR from."
      echo "jobs:"
      echo "  model: \"\""
      echo "  effort: \"\""
      echo "  marketplace: \"\""
    } > .flow/config.yaml
    [ -s .flow/config.yaml ] || die "could not write .flow/config.yaml"
    note ".flow/config.yaml written from the repository (adapters, base, pool). Review it."
    [ "$pool_n" -gt 3 ] && note ".flow/config.yaml: $pool_n worktrees already exist, so the pool lists all $pool_n and pool_max is $pool_max. Every one of them becomes a task slot: trim the list if some are not for the flow."
  fi
fi

# 2. Wrappers that know where the plugin is on this machine.
tmp="$scratch/notify"; printf '#!/bin/sh\n# Written by flow:init. Calls the flow plugin notify script: notify.sh <gate> <item> <message>.\nFLOW_PLUGIN="${FLOW_PLUGIN:-%s}"\nexec "$FLOW_PLUGIN/scripts/notify.sh" "$@"\n' "$plugin" > "$tmp"
install_file "$tmp" .flow/notify.sh 755
tmp="$scratch/run"; sed "s|^plugin=\"\${FLOW_PLUGIN:-}\"|plugin=\"\${FLOW_PLUGIN:-$plugin}\"|" "$plugin/templates/run-unattended.sh" > "$tmp"
[ -s "$tmp" ] || die "could not build run-unattended.sh"
install_file "$tmp" .flow/run-unattended.sh 755
for j in comments next retro; do
  tmp="$scratch/job-$j"
  printf '#!/bin/sh\n# Written by flow:init. Scheduled job: %s.sh <claude|codex> [args]. Logs to .flow/log/%s.log.\nFLOW_PLUGIN="${FLOW_PLUGIN:-%s}"\nexec "$FLOW_PLUGIN/jobs/%s.sh" "$@"\n' "$j" "$j" "$plugin" "$j" > "$tmp"
  install_file "$tmp" ".flow/jobs/$j.sh" 755
done

# 3. Claude worktree hooks. A plugin's WorktreeCreate hook does not fire for `claude --worktree`
# (verified 2026-10-10: the worktree is created before plugins load), so the project settings
# must name the hook. Stable wrappers under .flow/hooks/ keep the settings entry path-free.
for h in create remove; do
  tmp="$scratch/wt-$h"
  printf '#!/bin/sh\n# Written by flow:init. Claude Worktree%s hook: lands --worktree sessions in the pool.\nFLOW_PLUGIN="${FLOW_PLUGIN:-%s}"\nexec "$FLOW_PLUGIN/hooks/worktree-%s.sh" "$@"\n' "$( [ "$h" = create ] && echo Create || echo Remove )" "$plugin" "$h" > "$tmp"
  install_file "$tmp" ".flow/hooks/worktree-$h.sh" 755
done
settings_has_hook=0
[ -f .claude/settings.json ] && grep -q 'worktree-create.sh' .claude/settings.json && settings_has_hook=1

# 4. Codex: rules and agents (Codex cannot load agents or rules from a plugin).
install_file "$plugin/templates/flow.rules" .codex/rules/flow.rules "" guard
for src in "$plugin"/codex-agents/*.toml; do install_file "$src" ".codex/agents/$(basename "$src")" "" guard; done

# 5. .gitignore block.
tmp="$scratch/gitignore"
{
  [ -f .gitignore ] && awk '/^# flow:begin/{skip=1} !skip{print} /^# flow:end/{skip=0}' .gitignore
  echo "# flow:begin (written by flow:init; state that stays on this machine)"
  for p in .flow/items/ .flow/reports/ .flow/runs/ .flow/gates/ .flow/tmp/ .flow/log/ .flow/claim.json .flow/events.log .flow/.init-tmp/; do echo "$p"; done
  echo "# flow:end"
} > "$tmp"
install_file "$tmp" .gitignore

# 6. Gaps: config values the flow cannot run without. Reported every run; drift under --check.
if [ -f .flow/config.yaml ]; then
  [ -n "$(cfg pool | grep .)" ] || [ "$(cfg_or pool_max 0)" -gt 0 ] 2>/dev/null || gap ".flow/config.yaml: the pool is empty and pool_max is 0; list a worktree under pool: or set pool_max"
  [ -n "$(cfg base)" ] || gap ".flow/config.yaml: base is empty; name the branch tasks start from"
  for k in epic task bug; do a="$(cfg "adapters.$k")"; [ -z "$a" ] || [ -d "$plugin/adapters/$a" ] || gap ".flow/config.yaml: adapters.$k names $a, not an adapter"; done
  bad_auto="$(sed -n '/^auto_gates:/,/^[^ #]/p' .flow/config.yaml | grep -E '^  [A-Za-z]' | grep -v '^  plan-approval:' | sed 's/:.*//; s/^ *//' | head -1)"
  [ -z "$bad_auto" ] || gap ".flow/config.yaml: auto_gates lists $bad_auto; only plan-approval can be cleared by the flow"
  a="$(cfg_or adapters.default local)"; [ -d "$plugin/adapters/$a" ] || gap ".flow/config.yaml: adapters.default names $a, not an adapter"
fi

if [ "$check" -eq 1 ]; then
  [ "$drift" -eq 0 ] && echo "init: up to date with flow v$version"
  exit "$drift"
fi
write_stamp
if [ "$refused" -eq 1 ]; then echo "flow v$version: some copies were refused (see above); the rest is installed."; else echo "flow v$version installed."; fi
[ -n "$changed" ] && { echo "Changed:"; printf '%s' "$changed"; }
[ -n "$gaps" ] && { echo "Gaps (the flow cannot run until these are filled; init --check reports them):"; printf '%s' "$gaps"; }
echo "Next:"
echo "  - review .flow/config.yaml: the pool and pool_max, worktree_copy and worktree_setup, the base branch, the adapters, the gates, feel_test_paths, the Slack webhook"
echo "  - commit .flow/config.yaml, .flow/stamp, .flow/notify.sh, .flow/run-unattended.sh, .flow/jobs/, .flow/hooks/, .codex/ and .gitignore"
if [ "$settings_has_hook" -eq 0 ]; then
  echo "  - Claude: add the worktree hooks to .claude/settings.json so --worktree lands in the pool"
  echo "    (a plugin cannot provide them: the worktree is created before plugins load):"
  echo '      "hooks": { "WorktreeCreate": [ { "hooks": [ { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.flow/hooks/worktree-create.sh" } ] } ],'
  echo '                 "WorktreeRemove": [ { "hooks": [ { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/.flow/hooks/worktree-remove.sh" } ] } ] }'
fi
echo "  - Codex: trust the project .codex layer and every pool worktree in ~/.codex/config.toml:"
for p in "$main" $(cfg pool | sed "s|^\([^/]\)|$main/\1|"); do
  [ -d "$p" ] && echo "      [projects.\"$(cd "$p" && pwd)\"]" && echo "      trust_level = \"trusted\""
done
echo "    and run /hooks in Codex once to trust the plugin hooks (again after a plugin update)."
echo "  - Codex, interactive sessions in the main worktree that write into pool worktrees need the"
echo "    pool as writable roots in ~/.codex/config.toml: [sandbox_workspace_write] writable_roots = [..]"
echo "    (unverified on this version; unattended runs use -C <worktree> and do not need it)."
echo "  - schedule the jobs on this machine (each is a plain command; the lock skips an overlap):"
echo "      $main/.flow/jobs/comments.sh claude     every 30 min while PRs are open"
echo "      $main/.flow/jobs/next.sh claude         at the cadence new work should start"
echo "      $main/.flow/jobs/retro.sh claude        weekly"
echo "    Claude Desktop: a scheduled task whose prompt runs the command; launchd: a plist per job;"
echo "    Codex: the same commands with codex, from a scheduler (ChatGPT desktop Scheduled, or launchd)."
command -v python3 >/dev/null 2>&1 || echo "  - python3 is not installed; the flow scripts need it"
exit "$refused"
