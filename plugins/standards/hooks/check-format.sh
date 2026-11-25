#!/bin/sh
# Block a commit whose files fail the formatter check. The commands come from
# .standards/config.json: languages[].format is a list of {prefix, command}; {files} in the
# command stands for the staged files under that prefix (relative to the repo root), each one a
# separate argument.
. "$(dirname "$0")/lib.sh"
payload="$(read_payload)"
cmd="$(payload_command "$payload")"
[ -n "$cmd" ] || exit 0
seg="$(git_segment commit "$cmd")"
[ -n "$seg" ] || exit 0
use_working_git
cd "$(repo_root)" 2>/dev/null || exit 0
config="$(config_text)"
[ -n "$config" ] || exit 0
index="$(commit_index "$seg" "$cmd")"
discard_index_at_exit "$index"
key="$(commit_key "$index")"
passed_seen check-format "$key" && exit 0
hooks_folder="$(cd "$(dirname "$0")" && pwd)"
names="$(mktemp)" || exit 0
trap 'rm -f "$names"; [ -z "${discarded_index_folder:-}" ] || rm -rf "$discarded_index_folder"' EXIT
commit_files_null_byte_separated "$index" "$seg" > "$names"
[ -s "$names" ] || exit 0
failed=""
count="$(json_length "$config" "languages")"
i=0
while [ "$i" -lt "$count" ]; do
  extensions="$(json_list "$config" "languages.$i.extensions")"
  nformat="$(json_length "$config" "languages.$i.format")"
  j=0
  while [ "$j" -lt "$nformat" ]; do
    prefix="$(json_get "$config" "languages.$i.format.$j.prefix")"
    command="$(json_get "$config" "languages.$i.format.$j.command")"
    j=$((j + 1))
    [ -n "$command" ] || continue
    if ! output="$(xargs -0 sh "$hooks_folder/format-files.sh" "$prefix" "$extensions" "$command" < "$names" 2>&1)"; then
      failed="$failed  $command
$(printf '%s\n' "$output" | tail -40 | sed 's/^/    /')
"
    fi
  done
  i=$((i + 1))
done
if [ -z "$failed" ]; then passed_mark check-format "$index" "$key"; exit 0; fi
block "the formatter check failed" "$failed  L-03: run the formatter on the files above, re-stage, then commit again."
