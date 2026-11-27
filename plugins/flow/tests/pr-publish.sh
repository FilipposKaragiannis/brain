#!/bin/sh
# pr-publish.sh: the script that opens the pull request of the pr step. With no PR on the branch,
# open creates one from <reports>/pr-body.md with the Verification section swapped in and every
# image and video under evidence/ attached, so the body's references become asset URLs; it exits
# 0 with the URL, a --draft opens a draft, a text capture is never attached, and a base gh would
# read as an option is refused as a usage error. When a file does not upload, the PR is still made
# with the new section, the script exits 1 and names that file and every later one, and an empty
# file is named without stopping the rest; its retry edits that same PR. A failed lookup of the
# open PR makes none. After a later verify, refresh replaces the open PR's section whole, fenced
# heading lines and old asset URLs included, attaches the new files and keeps every line outside
# it; it makes no PR and leaves the body when the report was made at another commit. The report
# comes from the real verify, on the local adapter in a throwaway repo, and gh is the fake one.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
# shellcheck disable=SC2034,SC2154 # the fixtures this sources set and read these names, and check reads them inside its quoted conditions
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
. "$here/_verify_fixture.sh"

export FAKE_GH_DIR="$work/gh"
mkdir -p "$FAKE_GH_DIR" "$work/github" && cp "$plugin/tests/_fake_gh.py" "$FAKE_GH_DIR/"
ln -s "$plugin/tests/fake-gh.sh" "$work/github/gh"
PATH="$work/github:$PATH"; export PATH

published_exit=0
failed_exit=1
usage_exit=2
pull_request_title="Image evidence renders inline"
base_gh_reads_as_an_option="--web"
local_reference='](./evidence/'
pr_publish_constant() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import _pr_publish; print(getattr(_pr_publish, sys.argv[2]))' "$plugin/scripts" "$1"; }
created_line="$(pr_publish_constant CREATED_LINE)"
updated_line="$(pr_publish_constant UPDATED_LINE)"
not_uploaded_prefix="$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import _pr_publish as publish; print(publish.PROBLEM_LINE % (publish.NOT_UPLOADED % ""))' "$plugin/scripts")"
commit_test_command() {
  mkdir -p "$worktree/.standards" && printf '{"test": "%s"}\n' "$1" > "$worktree/.standards/config.json"
  git -C "$worktree" add .standards/config.json && git -C "$worktree" commit -qm "test command"
}
write_proofs() { printf '{"head": "%s", "proofs": %s}\n' "$(git -C "$worktree" rev-parse HEAD)" "$1" > "$reports/proofs.json"; }
# reset_fake_gh: a fake GitHub that holds no pull request and no uploaded file, and fails nothing.
reset_fake_gh() { printf '{"issues": []}\n' > "$FAKE_GH_DIR/issues.json"; : > "$FAKE_GH_DIR/calls.log"; rm -f "$FAKE_GH_DIR/fail" "$FAKE_GH_DIR/upload-fails"; }
# fail_upload_of <name>: the fake GitHub refuses to upload evidence/<name>.
fail_upload_of() { printf '%s\n' "$1" > "$FAKE_GH_DIR/upload-fails"; }
# seed_pull_request <body>: the fake GitHub holds an open pull request on the branch with that body.
seed_pull_request() {
  python3 -c 'import json,sys; json.dump({"issues": [], "pr": {"number": 91, "state": "OPEN", "isDraft": False, "mergedAt": None, "url": "https://gh/pull/91", "headRefName": sys.argv[2], "baseRefName": "main", "body": sys.argv[3]}}, open(sys.argv[1], "w"))' \
    "$FAKE_GH_DIR/issues.json" "$branch" "$1"
}
# write_body: the body the pr-creator writes, with the line where the Verification section goes.
write_body() {
  printf '## Summary\n\nEvidence shows inline.\n\n## Verification\n\n## Merge danger\n\n**Door:** two-way\n\nItem: %s\n' "$item" > "$reports/pr-body.md"
}
# publish <name> <base> [--draft]: pr-publish.sh open from the worktree on its branch; stdout in
# <name>.out, stderr in <name>.err and the exit code in <name>.code under the work folder.
publish() {
  publish_name="$1"; publish_base="$2"; shift 2
  (cd "$worktree" && "$plugin/scripts/pr-publish.sh" open "$reports" "$publish_base" "$branch" "$pull_request_title" "$@") \
    > "$work/$publish_name.out" 2> "$work/$publish_name.err"
  echo "$?" > "$work/$publish_name.code"
}
# refresh <name>: pr-publish.sh refresh from the worktree on its branch, its output kept as publish keeps it.
refresh() {
  (cd "$worktree" && "$plugin/scripts/pr-publish.sh" refresh "$reports" "$branch") > "$work/$1.out" 2> "$work/$1.err"
  echo "$?" > "$work/$1.code"
}
published() { cat "$work/$1.out"; }
# not_uploaded <name>: the evidence names the run of publish <name> said were not uploaded, one per line.
not_uploaded() { grep -F -e "$not_uploaded_prefix" "$work/$1.err" | cut -c "$((${#not_uploaded_prefix} + 1))-"; }
publish_code() { cat "$work/$1.code"; }
pull_request_field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pr", {}).get(sys.argv[2], ""))' "$FAKE_GH_DIR/issues.json" "$1"; }
# uploaded_names: the name under evidence/ of each file the fake GitHub holds, one per line, sorted.
uploaded_names() { python3 -c 'import json,os,sys; print("\n".join(sorted(os.path.relpath(path, sys.argv[2]) for path in json.load(open(sys.argv[1])).get("assets", []))))' "$FAKE_GH_DIR/issues.json" "$reports/evidence"; }
media_names_expected="$(printf 'run.mp4\nshot.png')"

echo "a new pull request with an image, a video and a text capture"
new_item publish "  capture: 'sh $work/capture-publish.sh'"
branch="$(git -C "$worktree" symbolic-ref --short HEAD)"
{ printf "evidence='%s/evidence'\n" "$reports"
  cat <<'CAPTURE'
mkdir -p "$evidence"
printf 'png bytes\n' > "$evidence/shot.png"
printf 'mp4 bytes\n' > "$evidence/run.mp4"
printf 'the login page greeted the owner\n' > "$evidence/notes.txt"
CAPTURE
} > "$work/capture-publish.sh"
commit_test_command true
write_proofs '[{"line": 1, "text": "the login screen shows", "grade": "live", "evidence": "evidence/shot.png"}]'
verify >/dev/null 2>&1
reset_fake_gh; write_body
publish ready main
check "Open_NoPullRequest_CreatesOneWithEveryMediaFileAttached: each image and video reaches the pull request" \
  '[ -n "$(pull_request_field url)" ] && [ "$(uploaded_names)" = "$media_names_expected" ]'
check "Open_NoPullRequest_BodyReferencesBecomeAssetUrls: a local path shows nothing on GitHub, an asset URL shows the file" \
  'pull_request_field body | grep -qF "](https://gh/assets/" && ! pull_request_field body | grep -qF -e "$local_reference"'
check "Open_AllUploaded_ExitsZero: the pr-creator goes on only when every file is attached" \
  '[ "$(publish_code ready)" = "$published_exit" ]'
check "Open_AllUploaded_PrintsTheUrl: the pr-creator records the pull request the script opened" \
  '[ -n "$(pull_request_field url)" ] && [ "$(published ready)" = "$(printf "$created_line" "$(pull_request_field url)")" ]'
check "Open_TextEvidence_IsNotAttached: gh takes only images and videos, and a text capture shows as an excerpt" \
  '[ -n "$(uploaded_names)" ] && ! uploaded_names | grep -qxF notes.txt'

echo "a draft"
reset_fake_gh; write_body
publish draft main --draft
check "Open_Draft_CreatesADraft: a pull request with a quiz waits as a draft until the owner passes it" \
  '[ "$(pull_request_field isDraft)" = True ]'

echo "a base gh would read as an option"
reset_fake_gh; write_body
publish option-base "$base_gh_reads_as_an_option"
check "Open_BaseStartingWithDash_RefusesWithUsageExit: a base that starts with a dash would reach gh as a flag" \
  '[ "$(publish_code option-base)" = "$usage_exit" ]'

echo "a pull request whose second file does not upload"
new_item partial "  capture: 'sh $work/capture-partial.sh'"
branch="$(git -C "$worktree" symbolic-ref --short HEAD)"
{ printf "evidence='%s/evidence'\n" "$reports"
  cat <<'CAPTURE'
mkdir -p "$evidence"
printf 'first png bytes\n' > "$evidence/first.png"
printf 'second mp4 bytes\n' > "$evidence/second.mp4"
printf 'third png bytes\n' > "$evidence/third.png"
CAPTURE
} > "$work/capture-partial.sh"
commit_test_command true
write_proofs '[{"line": 1, "text": "the login screen shows", "grade": "live", "evidence": "evidence/first.png"}]'
verify >/dev/null 2>&1
every_partial_name="$(printf 'first.png\nsecond.mp4\nthird.png')"
later_partial_names="$(printf 'second.mp4\nthird.png')"
reset_fake_gh; write_body; fail_upload_of second.mp4
publish second-fails main
partial_url="$(pull_request_field url)"
check "Open_SecondFileFails_CreatesThePullRequestAndExitsOne: the pull request exists, but the pr-creator must not go on as if every file showed" \
  '[ -n "$partial_url" ] && [ "$(publish_code second-fails)" = "$failed_exit" ]'
check "Open_SecondFileFails_NamesItAndEveryLaterFile: gh stops at the first failure, so the files after it were never sent" \
  '[ "$(not_uploaded second-fails)" = "$later_partial_names" ]'

echo "the retry after that partial upload"
rm -f "$FAKE_GH_DIR/upload-fails"
publish retry main
check "Open_RetryAfterPartialUpload_EditsTheSamePullRequest: a second pull request on the branch would split the review" \
  '[ -n "$partial_url" ] && [ "$(published retry)" = "$(printf "$updated_line" "$partial_url")" ]'
check "Open_RetryAfterPartialUpload_BodyHasNoLocalReferenceLeft: every file the first run missed shows once the retry uploads it" \
  'pull_request_field body | grep -qF "](https://gh/assets/" && ! pull_request_field body | grep -qF -e "$local_reference"'

echo "a pull request whose first file does not upload"
reset_fake_gh; write_body; fail_upload_of first.png
publish first-fails main
check "Open_FirstFileFails_CreatesThePullRequestWithoutAttachments: gh alone makes no pull request when nothing uploads" \
  '[ -n "$(pull_request_field url)" ] && [ -z "$(uploaded_names)" ]'
check "Open_FirstFileFails_NamesEveryFile: no file reached GitHub, so the owner must see each of them" \
  '[ "$(not_uploaded first-fails)" = "$every_partial_name" ]'

echo "an open pull request whose first file does not upload"
old_verdict="Verdict: fail at 0000000000000000000000000000000000000000"
new_verdict="$("$plugin/scripts/pr-report.sh" "$reports" | grep -m 1 -F 'Verdict: ')"
reset_fake_gh; seed_pull_request "$(printf '## Summary\n\nEvidence shows inline.\n\n## Verification\n\n%s\n\nItem: %s\n' "$old_verdict" "$item")"
fail_upload_of first.png
publish existing-first-fails main
check "Open_ExistingPullRequestFirstFileFails_BodyStillGetsTheNewSection: gh alone leaves the old verdict when nothing uploads" \
  '[ -n "$new_verdict" ] && pull_request_field body | grep -qF -e "$new_verdict" && ! pull_request_field body | grep -qF -e "$old_verdict"'

echo "an empty image"
reset_fake_gh; write_body; : > "$reports/evidence/blank.png"
publish empty-file main
rm -f "$reports/evidence/blank.png"
check "Open_EmptyMediaFile_PullRequestCreatedAndFileNamed: gh refuses an empty file before any upload, so it must not hold back the others" \
  '[ -n "$(pull_request_field url)" ] && not_uploaded empty-file | grep -qxF blank.png'

echo "a lookup of the open pull request that fails"
reset_fake_gh; write_body; printf '1\nthe lookup is refused\npr list\n' > "$FAKE_GH_DIR/fail"
publish lookup-fails main
check "Open_LookupFails_ExitsOneWithoutCreating: a create after a failed lookup could open a second pull request on the branch" \
  '[ "$(publish_code lookup-fails)" = "$failed_exit" ] && [ -z "$(pull_request_field url)" ]'

echo "a re-verify after the pull request exists"
new_item refresh "  capture: 'sh $work/capture-refresh.sh'"
branch="$(git -C "$worktree" symbolic-ref --short HEAD)"
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
commit_change() { printf '%s\n' "$1" >> "$worktree/change.txt" && git -C "$worktree" commit -qam "$1"; }
fenced_heading_line="## Heading inside the first excerpt"
section_heading="$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import _pr_report; print(_pr_report.SECTION_HEADING)' "$plugin/scripts")"
one_section=1
owner_summary="The owner rewrote this summary."
write_refresh_capture before.png "$fenced_heading_line"
commit_test_command true
write_proofs '[{"line": 1, "text": "the login screen shows", "grade": "live", "evidence": "evidence/before.png"}]'
verify >/dev/null 2>&1
old_verdict="$("$plugin/scripts/pr-report.sh" "$reports" | grep -m 1 -F 'Verdict: ')"
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
new_verdict="$("$plugin/scripts/pr-report.sh" "$reports" | grep -m 1 -F 'Verdict: ')"
refresh refreshed
check "Refresh_NewVerdict_ReplacesTheVerificationSection: the reviewer reads the verdict of the commit under review" \
  '[ -n "$new_verdict" ] && [ "$new_verdict" != "$old_verdict" ] && pull_request_field body | grep -qF -e "$new_verdict" && ! pull_request_field body | grep -qF -e "$old_verdict"'
check "Refresh_NewEvidence_AttachesTheNewFiles: an image the later verify captured shows only once it is uploaded" \
  'uploaded_names | grep -qxF after.png'
check "Refresh_OldAssetUrls_AreGoneFromTheBody: an image of the old verdict beside the new one would show a run that no longer holds" \
  '[ -n "$old_asset_urls" ] && ! pull_request_field body | grep -qF -e "$old_asset_urls"'
check "Refresh_OwnerEditedSummary_StaysAsTheOwnerLeftIt: the Summary is outside the section, so the PR's own text is kept, not the local file's" \
  'pull_request_field body | grep -qxF -e "$owner_summary"'
check "Refresh_Footer_StaysAsItWas: the footer line after the section is what closes the item on merge" \
  'pull_request_field body | grep -qxF -e "Item: $item"'
check "Refresh_ExcerptHoldingAHeadingLine_SwapsTheWholeSection: a heading line in a fence is excerpt text, and the old section must go whole" \
  'printf "%s\n" "$body_before_refresh" | grep -qxF -e "$fenced_heading_line" && ! pull_request_field body | grep -qxF -e "$fenced_heading_line" && [ "$(pull_request_field body | grep -cxF -e "$section_heading")" -eq "$one_section" ]'

echo "a refresh with no open pull request"
no_open_pull_request="$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import _pr_refresh; print(_pr_refresh.NO_OPEN_PULL_REQUEST % sys.argv[2])' "$plugin/scripts" "$branch")"
reset_fake_gh
refresh no-pull-request
check "Refresh_NoPullRequest_ExitsOneAndCreatesNone: a refresh runs where a PR exists, and a new one would skip the pr step's checks" \
  '[ "$(publish_code no-pull-request)" = "$failed_exit" ] && [ -z "$(pull_request_field url)" ] && grep -qF -e "$no_open_pull_request" "$work/no-pull-request.err"'

echo "a refresh with a report made at an earlier commit"
stale_body="$(printf '## Summary\n\nEvidence shows inline.\n\n## Verification\n\n%s\n\nItem: %s\n' "$new_verdict" "$item")"
reset_fake_gh; seed_pull_request "$stale_body"
commit_change "a commit verify never saw"
refresh another-commit
check "Refresh_ReportOnAnotherCommit_Refuses: a verdict of an earlier commit would vouch for code it never checked" \
  '[ "$(publish_code another-commit)" = "$failed_exit" ] && [ "$(pull_request_field body)" = "$stale_body" ]'

if [ "$fails" -eq 0 ]; then echo "pr-publish: ok"; else echo "pr-publish: $fails failed"; exit 1; fi
