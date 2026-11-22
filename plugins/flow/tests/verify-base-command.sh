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

check_field() { python3 -c 'import json,sys; found=[check for check in json.load(open(sys.argv[1]))["checks"] if check["name"]==sys.argv[2]]; print(found[0].get(sys.argv[3], "") if found else "no such check")' "$reports/verify.json" "$1" "$2"; }
new_item unresolved ""
mkdir -p "$worktree/.standards" "$worktree/source"
cat > "$worktree/.standards/config.json" <<'JSON'
{"test":[{"name":"received","command":"echo {verify_base}","paths":["source/**"]}]}
JSON
echo first > "$worktree/source/file"
git -C "$worktree" add .standards/config.json source/file && git -C "$worktree" commit -qm first
verify >/dev/null
verify --base no-such-base >/dev/null
unresolved_result=$?
check "UnresolvedBase_RunsTheCheckWithPaths because an unknown change list cannot show that nothing under its paths changed" \
  '[ "$unresolved_result" -eq 0 ] && [ "$(check_field "tests received" status)" = pass ]'
check "UnresolvedBase_GivesTheCommandUnavailable because the command must know it cannot narrow its run" \
  '[ "$(check_field "tests received" command)" = "echo unavailable" ]'
check "UnresolvedBase_ReusesNoPassFromAResolvedBase because that pass proved a narrower comparison" \
  '[ -z "$(check_field "tests received" reused_from)" ]'
check "UnresolvedBase_IsNamedInTheReport because a reader must see the comparison was unavailable" \
  'grep -q "(unavailable)" "$reports/verify.md" && grep -q "no-such-base cannot be resolved" "$reports/verify.log"'
exit "$((fails > 0))"
