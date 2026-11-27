#!/bin/sh
# pr-refresh.sh: pr-publish.sh refresh, run after a later verify once the pull request exists. It
# replaces the open PR's Verification section whole, fenced heading lines and old asset URLs
# included, attaches the new files and keeps every line outside it; it makes no PR when none is
# open, and it leaves the body when the report was made at another commit. The reports come from
# the real verify, on the local adapter in a throwaway repo, and gh is the fake one.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
# shellcheck disable=SC2034,SC2154 # the fixtures this sources set and read these names, and check reads them inside its quoted conditions
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
. "$here/_verify_fixture.sh"
. "$here/_pr_publish_fixture.sh"

# refresh <name>: pr-publish.sh refresh from the worktree on its branch, its output kept as publish keeps it.
refresh() {
  (cd "$worktree" && "$plugin/scripts/pr-publish.sh" refresh "$reports" "$branch") > "$work/$1.out" 2> "$work/$1.err"
  echo "$?" > "$work/$1.code"
}
# write_refresh_capture <image name> <excerpt line>: the next verify captures that image and a text file holding that line.
write_refresh_capture() {
  { printf "evidence='%s/evidence'\nimage_name='%s'\nexcerpt_line='%s'\n" "$reports" "$1" "$2"
    cat <<'CAPTURE'
mkdir -p "$evidence"
printf 'png bytes\n' > "$evidence/$image_name"
printf 'the capture of this round\n%s\n' "$excerpt_line" > "$evidence/notes.txt"
CAPTURE
  } > "$work/capture-refresh.sh"
}
# commit_change <line>: a new commit on the task branch, as a fix pushed after review is.
commit_change() { printf '%s\n' "$1" >> "$worktree/change.txt" && git -C "$worktree" add change.txt && git -C "$worktree" commit -qm "$1"; }
fenced_heading_line="## Heading inside the first excerpt"
section_heading="$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import _pr_report; print(_pr_report.SECTION_HEADING)' "$plugin/scripts")"
one_section=1
owner_summary="The owner rewrote this summary."

echo "a re-verify after the pull request exists"
new_item refresh "  capture: 'sh $work/capture-refresh.sh'"
branch="$(git -C "$worktree" symbolic-ref --short HEAD)"
write_refresh_capture before.png "$fenced_heading_line"
commit_test_command true
write_proofs '[{"line": 1, "text": "the login screen shows", "grade": "live", "evidence": "evidence/before.png"}]'
verify >/dev/null 2>&1
old_verdict="$(report_verdict)"
reset_fake_gh; write_body
publish refresh-open main
python3 -c 'import json,sys; state = json.load(open(sys.argv[1])); state["pr"]["body"] = state["pr"]["body"].replace("Evidence shows inline.", sys.argv[2]); json.dump(state, open(sys.argv[1], "w"))' \
  "$FAKE_GH_DIR/issues.json" "$owner_summary"
body_before_refresh="$(pull_request_field body)"
old_asset_urls="$(printf '%s\n' "$body_before_refresh" | grep -o 'https://gh/assets/[0-9]*)')"
commit_change "the second round"
write_refresh_capture after.png "the second capture"
write_proofs '[{"line": 1, "text": "the login screen shows", "grade": "live", "evidence": "evidence/after.png"}]'
verify >/dev/null 2>&1
new_verdict="$(report_verdict)"
refresh refreshed
check "Refresh_NewVerdict_BodyHoldsTheNewVerdict: the reviewer reads the verdict of the commit under review" \
  '[ -n "$new_verdict" ] && pull_request_field body | grep -qF -e "$new_verdict"'
check "Refresh_NewVerdict_OldVerdictIsGone: a verdict of an earlier commit beside the new one leaves the reviewer to guess" \
  '[ -n "$old_verdict" ] && ! pull_request_field body | grep -qF -e "$old_verdict"'
check "Refresh_EveryFileUploaded_ExitsZero: the comments pass reports a clean refresh only when every file is attached" \
  '[ "$(publish_code refreshed)" = "$published_exit" ]'
check "Refresh_NewEvidence_AttachesTheNewFiles: an image the later verify captured shows only once it is uploaded" \
  'uploaded_names | grep -qxF after.png'
check "Refresh_OldAssetUrls_AreGoneFromTheBody: an image of the old verdict beside the new one would show a run that no longer holds" \
  '[ -n "$old_asset_urls" ] && ! pull_request_field body | grep -qF -e "$old_asset_urls"'
check "Refresh_OwnerEditedSummary_StaysAsTheOwnerLeftIt: the Summary is outside the section, so the PR's own text is kept, not the local file's" \
  'pull_request_field body | grep -qxF -e "$owner_summary"'
check "Refresh_Footer_StaysAsItWas: the footer line after the section is what closes the item on merge" \
  'pull_request_field body | grep -qxF -e "Item: $item"'
check "Refresh_ExcerptHoldingAHeadingLine_OldExcerptIsGone: a heading line in a fence is excerpt text, so the swap must not stop at it" \
  'printf "%s\n" "$body_before_refresh" | grep -qxF -e "$fenced_heading_line" && ! pull_request_field body | grep -qxF -e "$fenced_heading_line"'
check "Refresh_ExcerptHoldingAHeadingLine_BodyHoldsOneSection: a section cut short at the fenced line leaves a second section behind" \
  '[ "$(pull_request_field body | grep -cxF -e "$section_heading")" -eq "$one_section" ]'

echo "a refresh with no open pull request"
no_open_pull_request="$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import _pr_refresh; print(_pr_refresh.NO_OPEN_PULL_REQUEST % sys.argv[2])' "$plugin/scripts" "$branch")"
reset_fake_gh
refresh no-pull-request
check "Refresh_NoPullRequest_ExitsOne: the comments pass must learn that no body was refreshed" \
  '[ "$(publish_code no-pull-request)" = "$failed_exit" ]'
check "Refresh_NoPullRequest_CreatesNone: a refresh runs where a PR exists, and a new one would skip the pr step's checks" \
  '[ -z "$(pull_request_field url)" ]'
check "Refresh_NoPullRequest_SaysNoOpenPullRequest: the owner learns why the body kept its old verdict" \
  '[ -n "$no_open_pull_request" ] && grep -qF -e "$no_open_pull_request" "$work/no-pull-request.err"'

echo "a refresh with a report made at an earlier commit"
stale_body="$(printf '## Summary\n\nEvidence shows inline.\n\n## Verification\n\n%s\n\nItem: %s\n' "$new_verdict" "$item")"
reset_fake_gh; seed_pull_request "$stale_body"
commit_change "a commit verify never saw"
refresh another-commit
check "Refresh_ReportOnAnotherCommit_ExitsOne: a verdict of an earlier commit would vouch for code it never checked" \
  '[ "$(publish_code another-commit)" = "$failed_exit" ]'
check "Refresh_ReportOnAnotherCommit_BodyStaysAsItWas: the stale verdict must not replace what the pull request holds" \
  '[ "$(pull_request_field body)" = "$stale_body" ]'

if [ "$fails" -eq 0 ]; then echo "pr-refresh: ok"; else echo "pr-refresh: $fails failed"; exit 1; fi
