#!/bin/sh
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
. "$here/_verify_fixture.sh"

new_item comparison ""
git -C "$worktree" branch original-base
mkdir -p "$worktree/.standards" "$worktree/source"
cat > "$worktree/.standards/config.json" <<'JSON'
{"test":[{"name":"comparison","command":"git diff --quiet {verify_base} HEAD -- source/file","paths":["source/**"]}]}
JSON
echo first > "$worktree/source/file"
git -C "$worktree" add .standards/config.json source/file && git -C "$worktree" commit -qm first
git -C "$worktree" branch second-base
echo other > "$worktree/source/other"
git -C "$worktree" add source/other && git -C "$worktree" commit -qm other

verify --base second-base >/dev/null
same_result=$?
check "ComparisonAgainstMatchingSource_Passes because the command compares the requested base" \
  '[ "$same_result" -eq 0 ]'
verify --base original-base >/dev/null
different_result=$?
check "ComparisonAgainstDifferentSource_Fails because a pass from the other base cannot prove this comparison" \
  '[ "$different_result" -eq 1 ] && [ "$(report_status)" = fail ]'
exit "$((fails > 0))"
