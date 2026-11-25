#!/bin/sh
# Block a commit that touches owner-only files (formatter, analyzer and CI config) unless the
# commit message carries the [config] marker. The list comes from .standards/config.json "protected".
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
commit_has_marker "$seg" "[config]" && exit 0
hooks_folder="$(cd "$(dirname "$0")" && pwd)"
patterns="$(json_list "$config" "protected" | sed 's|\*\*|*|g')"
hits="$(changed_files_null_byte_separated "$seg" | xargs -0 sh "$hooks_folder/files-matching-patterns.sh" "$patterns")"
[ -n "$hits" ] || exit 0
block "protected configuration files in this commit. They are owner-only. Add [config] to the commit message when the owner approved the change." "$hits"
