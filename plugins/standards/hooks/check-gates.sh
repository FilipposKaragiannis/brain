#!/bin/sh
# Run the project's own gates, declared in .standards/config.json "gates" (no project script needed):
#   {"name": "build", "command": "dotnet build …", "paths": ["src/**"], "when": ["commit", "ci"]}
#     a command gate: runs the command from the repo root before a commit (when one of the files
#     in the commit matches a path glob; no paths means always), before a push ("push"), or per
#     commit in CI ("ci", via check-range.sh). Blocks (exit 2) when the command fails. "when"
#     defaults to ["commit"]. Globs match like "protected": ** and * both cross directories.
#     The command sees STANDARDS_COMMIT_MESSAGE (the message of the commit, empty before a push)
#     and STANDARDS_STAGE (commit, push or ci), and none of git's repository variables (GIT_DIR,
#     GIT_INDEX_FILE, GIT_WORK_TREE, every name `git rev-parse --local-env-vars` lists): the git
#     hooks export them, and a gate that runs tests would aim the tests' git at this repository.
#   {"name": "golden-pause", "command": "tools/check-golden.sh", "marker": "[closeout #218]"}
#     a command gate with a marker: a commit whose message carries the marker skips the gate. The
#     git pre-commit hook has no message yet, so it leaves marked gates to the commit-msg hook
#     (STANDARDS_GATES=unmarked there, =marked in commit-msg; unset runs both).
#   {"name": "golden-pause", "forbid": ["update-golden"], "marker": "[closeout #218]"}
#     a forbidden-command gate: blocks a command that runs one of the texts, unless the command,
#     or the commit message it carries, holds the marker. The text must stand as a word in the
#     part of the command that runs: heredoc bodies, comments and quoted text do not count, except
#     the argument of `sh -c`, `bash -c` and `eval`. Agent hosts only: a git hook never sees a
#     command.
#   {"name": "whole-suite", "forbid_run": ["tools/test.sh"], "marker": "[whole-suite]"}
#     a forbidden-program gate: blocks a command that starts one of the programs, as written or
#     at the end of a longer path, through a shell, env, exec, nohup, nice or timeout too. A
#     command that only names the path (git add, sed, grep, sh -n) starts nothing and passes.
#     Use it for a script that must not run by hand; forbid is for a verb passed as an argument.
# Agent hosts feed the Bash payload on stdin; the git hooks feed a plain `git commit` or `git push`;
# check-range.sh sets STANDARDS_STAGE=ci so only the gates that list "ci" run. An agent's commit
# runs the gates once: the agent hook records the content the commit will hold, and git's hooks
# skip that same content (passed_mark and passed_seen in commit-index.sh).
. "$(dirname "$0")/lib.sh"
payload="$(read_payload)"
cmd="$(payload_command "$payload")"
[ -n "$cmd" ] || exit 0
set -f   # the globs stay literal
commit_seg="$(git_segment commit "$cmd")"
push_seg="$(git_segment push "$cmd")"
stage=""
if [ "${STANDARDS_STAGE:-}" = ci ]; then stage=ci
elif [ -n "$commit_seg" ]; then stage=commit
elif [ -n "$push_seg" ]; then stage=push; fi
use_working_git
cd "$(repo_root)" 2>/dev/null || exit 0
config="$(config_text)"
[ -n "$config" ] || exit 0
[ -n "$stage" ] || case "$config" in *'"forbid'*) ;; *) exit 0 ;; esac
index=""
[ -n "$commit_seg" ] && index="$(commit_index "$commit_seg" "$cmd")"
discard_index_at_exit "$index"
key="$(commit_key "$index")"
passed_seen check-gates "$key" && exit 0
gates="$(json_list "$config" gates)"
count="$(printf '%s\n' "$gates" | grep -c .)"
[ "$count" -gt 0 ] || exit 0
files=""
[ -n "$commit_seg" ] && files="$(commit_files "$index" "$commit_seg")"
commit_msg=""
[ -n "$commit_seg" ] && commit_msg="$(commit_message_text "$commit_seg")"
code="$(command_code "$cmd")"
gate_mode="${STANDARDS_GATES:-}"
failed=""
i=0
while [ "$i" -lt "$count" ]; do
  gate="$(printf '%s\n' "$gates" | sed -n "$((i + 1))p")"
  i=$((i + 1))
  [ -n "$stage" ] || case "$gate" in *'"forbid'*) ;; *) continue ;; esac
  name="$(json_get "$gate" name)"; [ -n "$name" ] || name="gates[$((i - 1))]"
  marker="$(json_get "$gate" marker)"
  forbid="$(json_list "$gate" forbid)"
  forbid_run="$(json_list "$gate" forbid_run)"
  if [ -n "$forbid$forbid_run" ]; then
    hit=""; said="contains"
    while IFS= read -r text; do
      [ -n "$text" ] || continue
      code_has_word "$code" "$text" && hit="$text"
    done <<FORBID
$forbid
FORBID
    while IFS= read -r program; do
      [ -n "$program" ] || continue
      code_runs "$code" "$program" && { hit="$program"; said="runs"; }
    done <<FORBID_RUN
$forbid_run
FORBID_RUN
    [ -n "$hit" ] || continue
    if [ -n "$marker" ]; then
      printf '%s' "$cmd" | grep -qiF -- "$marker" && continue
      [ -n "$commit_seg" ] && commit_has_marker "$commit_seg" "$marker" && continue
      block "gate $name: the command $said \"$hit\"" "  $cmd
  It is blocked until the owner approves it: then add $marker to the command or the commit message."
    fi
    block "gate $name: the command $said \"$hit\"" "  $cmd"
  fi
  [ -n "$stage" ] || continue
  command="$(json_get "$gate" command)"
  paths="$(json_list "$gate" paths)"
  when="$(json_list "$gate" when | tr '\n' ' ')"; [ -n "$(printf '%s' "$when" | tr -d ' ')" ] || when="commit"
  [ -n "$command" ] || continue
  case " $when " in *" $stage "*) ;; *) continue ;; esac
  if [ -n "$marker" ]; then
    [ "$gate_mode" = unmarked ] && continue
    [ -n "$commit_seg" ] && commit_has_marker "$commit_seg" "$marker" && continue
  else
    [ "$gate_mode" = marked ] && continue
  fi
  if [ -n "$paths" ] && [ "$stage" != push ]; then
    match=0
    for pattern in $paths; do
      pattern="$(printf '%s' "$pattern" | sed 's|\*\*|*|g')"
      # shellcheck disable=SC2254
      for file in $files; do case "$file" in $pattern) match=1 ;; esac; done
    done
    [ "$match" -eq 1 ] || continue
  fi
  # shellcheck disable=SC2046
  if ! output="$(unset $(git rev-parse --local-env-vars); STANDARDS_COMMIT_MESSAGE="$commit_msg" STANDARDS_STAGE="$stage" sh -c "$command" 2>&1)"; then
    failed="$failed  gate $name failed: $command
$(printf '%s\n' "$output" | tail -40 | sed 's/^/    /')
${marker:+    The owner can approve it: add $marker to the commit message.
}"
  fi
done
if [ -z "$failed" ]; then [ -n "$commit_seg" ] && passed_mark check-gates "$index" "$key"; exit 0; fi
block "a project gate failed" "$failed  Fix the findings, re-stage, then try again."
