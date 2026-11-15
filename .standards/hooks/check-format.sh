#!/bin/sh
# Block a commit whose files fail the formatter check. The commands come from
# .standards/config.json: languages[].format is a list of {prefix, command}; {files} in the
# command is replaced by the staged files under that prefix (relative to the repo root).
. "$(dirname "$0")/lib.sh"
payload="$(read_payload)"
cmd="$(payload_command "$payload")"
[ -n "$cmd" ] || exit 0
seg="$(git_segment commit "$cmd")"
[ -n "$seg" ] || exit 0
cd "$(repo_root)" 2>/dev/null || exit 0
config="$(config_text)"
[ -n "$config" ] || exit 0
passed_seen check-format && exit 0   # the agent hook already passed this index
files="$(changed_files "$seg")"
[ -n "$files" ] || exit 0
failed=""
count="$(json_length "$config" "languages")"
i=0
while [ "$i" -lt "$count" ]; do
  exts="$(json_list "$config" "languages.$i.extensions")"
  nformat="$(json_length "$config" "languages.$i.format")"
  j=0
  while [ "$j" -lt "$nformat" ]; do
    prefix="$(json_get "$config" "languages.$i.format.$j.prefix")"
    command="$(json_get "$config" "languages.$i.format.$j.command")"
    j=$((j + 1))
    [ -n "$command" ] || continue
    scoped=""
    for file in $files; do
      case "$file" in "$prefix"*) ;; *) continue ;; esac
      for ext in $exts; do case "$file" in *"$ext") scoped="$scoped $file" ;; esac; done
    done
    [ -n "$scoped" ] || continue
    run="$(printf '%s' "$command" | sed "s|{files}|$(printf '%s' "$scoped" | sed 's|[&|]|\\&|g')|g")"
    if ! output="$(sh -c "$run" 2>&1)"; then
      failed="$failed  $run
$(printf '%s\n' "$output" | tail -40 | sed 's/^/    /')
"
    fi
  done
  i=$((i + 1))
done
if [ -z "$failed" ]; then passed_mark check-format "$seg"; exit 0; fi
block "the formatter check failed" "$failed  L-03: run the formatter on the files above, re-stage, then commit again."
