#!/bin/sh
# Run the project's own gates, declared in .standards/config.json "gates" (no project script needed):
#   {"name": "build", "command": "dotnet build …", "paths": ["src/**"], "when": ["commit", "ci"]}
#     a command gate: runs the command from the repo root before a commit (when one of the files
#     in the commit matches a path glob; no paths means always), before a push ("push"), or per
#     commit in CI ("ci", via check-range.sh). Blocks (exit 2) when the command fails. "when"
#     defaults to ["commit"]. Globs match like "protected": ** and * both cross directories.
#   {"name": "golden-pause", "forbid": ["update-golden"], "marker": "[closeout #218]"}
#     a forbidden-command gate: blocks any command that contains one of the texts, unless the
#     command, or the commit message it carries, holds the marker. Agent hosts only: a git hook
#     never sees a command.
# Agent hosts feed the Bash payload on stdin; the git hooks feed a plain `git commit` or `git push`;
# check-range.sh sets STANDARDS_STAGE=ci so only the gates that list "ci" run.
. "$(dirname "$0")/lib.sh"
payload="$(read_payload)"
cmd="$(payload_command "$payload")"
[ -n "$cmd" ] || exit 0
cd "$(repo_root)" 2>/dev/null || exit 0
config="$(config_text)"
[ -n "$config" ] || exit 0
count="$(json_length "$config" gates)"
[ "$count" -gt 0 ] || exit 0
set -f   # the globs stay literal
commit_seg="$(git_segment commit "$cmd")"
push_seg="$(git_segment push "$cmd")"
stage=""
if [ "${STANDARDS_STAGE:-}" = ci ]; then stage=ci
elif [ -n "$commit_seg" ]; then stage=commit
elif [ -n "$push_seg" ]; then stage=push; fi
files=""
[ -n "$commit_seg" ] && files="$(changed_files "$commit_seg")"
failed=""
i=0
while [ "$i" -lt "$count" ]; do
  name="$(json_get "$config" "gates.$i.name")"; [ -n "$name" ] || name="gates[$i]"
  command="$(json_get "$config" "gates.$i.command")"
  marker="$(json_get "$config" "gates.$i.marker")"
  forbid="$(json_list "$config" "gates.$i.forbid")"
  paths="$(json_list "$config" "gates.$i.paths")"
  when="$(json_list "$config" "gates.$i.when" | tr '\n' ' ')"; [ -n "$(printf '%s' "$when" | tr -d ' ')" ] || when="commit"
  i=$((i + 1))
  if [ -n "$forbid" ]; then
    hit=""
    while IFS= read -r text; do
      [ -n "$text" ] || continue
      case "$cmd" in *"$text"*) hit="$text" ;; esac
    done <<FORBID
$forbid
FORBID
    [ -n "$hit" ] || continue
    if [ -n "$marker" ]; then
      printf '%s' "$cmd" | grep -qiF -- "$marker" && continue
      [ -n "$commit_seg" ] && commit_has_marker "$commit_seg" "$marker" && continue
      block "gate $name: the command contains \"$hit\"" "  $cmd
  It is blocked until the owner approves it: then add $marker to the command or the commit message."
    fi
    block "gate $name: the command contains \"$hit\"" "  $cmd"
  fi
  [ -n "$command" ] && [ -n "$stage" ] || continue
  case " $when " in *" $stage "*) ;; *) continue ;; esac
  if [ -n "$paths" ] && [ "$stage" != push ]; then
    match=0
    for pattern in $paths; do
      pattern="$(printf '%s' "$pattern" | sed 's|\*\*|*|g')"
      # shellcheck disable=SC2254
      for file in $files; do case "$file" in $pattern) match=1 ;; esac; done
    done
    [ "$match" -eq 1 ] || continue
  fi
  if ! output="$(sh -c "$command" 2>&1)"; then
    failed="$failed  gate $name failed: $command
$(printf '%s\n' "$output" | tail -40 | sed 's/^/    /')
"
  fi
done
[ -n "$failed" ] || exit 0
block "a project gate failed" "$failed  Fix the findings, re-stage, then try again."
