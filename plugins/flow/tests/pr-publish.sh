#!/bin/sh
# pr-publish.sh: pr-publish.sh open, the script that opens the pull request of the pr step. With no
# PR on the branch, it creates one from <reports>/pr-body.md with the Verification section swapped
# in and every image and video under evidence/ attached, so the body's references become asset
# URLs; it exits 0 with the URL, a --draft opens a draft, a text capture is never attached, and a
# base gh would read as an option is refused as a usage error. When a file does not upload, the PR
# is still made with the new section, the script exits 1 and names that file and every later one,
# and an empty file is named without stopping the rest; its retry edits that same PR. An image
# whose name holds a line break adds no line to the body and is never uploaded. More images
# than gh takes in one call all reach the PR in batches, their references all rewritten, and a
# failed later batch names each of its files. A failed lookup of the open PR makes none, and a
# fork's PR on a branch of the same name is left as it was, beside ours or alone. The report
# comes from the real verify, on the local adapter in a throwaway repo, and gh is the fake one.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
# shellcheck disable=SC2034,SC2154 # the fixtures this sources set and read these names, and check reads them inside its quoted conditions
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
. "$here/_verify_fixture.sh"
. "$here/_pr_publish_fixture.sh"

base_gh_reads_as_an_option="--web"
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
created_verdict="$(report_verdict)"
reset_fake_gh; write_body
publish ready main
check "Open_NoPullRequest_EveryMediaFileIsUploaded: each image and video reaches the pull request" \
  '[ "$(uploaded_names)" = "$media_names_expected" ]'
check "Open_NoPullRequest_BodyHoldsTheVerdict: the reviewer reads the verdict of this verify in the new pull request" \
  '[ -n "$created_verdict" ] && pull_request_field body | grep -qF -e "$created_verdict"'
check "Open_NoPullRequest_BodyReferencesBecomeAssetUrls: a local path shows nothing on GitHub, an asset URL shows the file" \
  'pull_request_field body | grep -qF -e "$asset_reference" && ! pull_request_field body | grep -qF -e "$local_reference"'
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
check "Open_BaseStartingWithDash_CreatesNoPullRequest: a refused base must not reach gh at all" \
  '[ -z "$(pull_request_field url)" ]'

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
check "Open_SecondFileFails_PullRequestStillExists: gh makes the pull request with the files it uploaded before the failure" \
  '[ -n "$partial_url" ]'
check "Open_SecondFileFails_ExitsOne: the pr-creator must not go on as if every file showed" \
  '[ "$(publish_code second-fails)" = "$failed_exit" ]'
check "Open_SecondFileFails_NamesItAndEveryLaterFile: gh stops at the first failure, so the files after it were never sent" \
  '[ "$(not_uploaded second-fails)" = "$later_partial_names" ]'

echo "the retry after that partial upload"
rm -f "$FAKE_GH_DIR/upload-fails"
publish retry main
check "Open_RetryAfterPartialUpload_EditsTheSamePullRequest: a second pull request on the branch would split the review" \
  '[ -n "$partial_url" ] && [ "$(published retry)" = "$(printf "$updated_line" "$partial_url")" ]'
check "Open_RetryAfterPartialUpload_BodyHasNoLocalReferenceLeft: every file the first run missed shows once the retry uploads it" \
  'pull_request_field body | grep -qF -e "$asset_reference" && ! pull_request_field body | grep -qF -e "$local_reference"'

echo "a pull request whose first file does not upload"
reset_fake_gh; write_body; fail_upload_of first.png
publish first-fails main
check "Open_FirstFileFails_PullRequestStillExists: gh alone makes no pull request when nothing uploads, so the script makes it" \
  '[ -n "$(pull_request_field url)" ]'
check "Open_FirstFileFails_ExitsOne: a pull request with no file attached is a failed pr step" \
  '[ "$(publish_code first-fails)" = "$failed_exit" ]'
check "Open_FirstFileFails_NamesEveryFile: no file reached GitHub, so the owner must see each of them" \
  '[ "$(not_uploaded first-fails)" = "$every_partial_name" ]'

echo "an open pull request whose first file does not upload"
old_verdict="Verdict: fail at 0000000000000000000000000000000000000000"
new_verdict="$(report_verdict)"
reset_fake_gh; seed_pull_request "$(printf '## Summary\n\nEvidence shows inline.\n\n## Verification\n\n%s\n\nItem: %s\n' "$old_verdict" "$item")"
fail_upload_of first.png
publish existing-first-fails main
check "Open_ExistingPullRequestFirstFileFails_BodyHoldsTheNewVerdict: gh alone leaves the body as it was when nothing uploads" \
  '[ -n "$new_verdict" ] && pull_request_field body | grep -qF -e "$new_verdict"'
check "Open_ExistingPullRequestFirstFileFails_OldVerdictIsGone: two verdicts in one body leave the reviewer to guess which holds" \
  '[ -n "$(pull_request_field body)" ] && ! pull_request_field body | grep -qF -e "$old_verdict"'
check "Open_ExistingPullRequestFirstFileFails_ExitsOne: an update with no file attached is a failed pr step" \
  '[ "$(publish_code existing-first-fails)" = "$failed_exit" ]'

echo "an empty image"
reset_fake_gh; write_body; : > "$reports/evidence/blank.png"
publish empty-file main
rm -f "$reports/evidence/blank.png"
check "Open_EmptyMediaFile_PullRequestStillExists: gh refuses an empty file before any upload, so it must not hold back the others" \
  '[ -n "$(pull_request_field url)" ]'
check "Open_EmptyMediaFile_NamesTheEmptyFile: the owner learns which capture never reached the pull request" \
  'not_uploaded empty-file | grep -qxF blank.png'
check "Open_EmptyMediaFile_ExitsOne: a capture missing from the pull request is a failed pr step" \
  '[ "$(publish_code empty-file)" = "$failed_exit" ]'

echo "an image whose name holds a line break"
injected_line="Resolves #1"
line_break_name="$(printf 'shot\n%s\nend.png' "$injected_line")"
reset_fake_gh; write_body; printf 'png bytes\n' > "$reports/evidence/$line_break_name"
publish line-break-name main
rm -f "$reports/evidence/$line_break_name"
check "Open_MediaNameWithLineBreak_BodyHoldsNoLineOfIt: a line from a file name such as a closing keyword would close an issue on merge" \
  '[ -n "$(pull_request_field body)" ] && ! pull_request_field body | grep -qxF -e "$injected_line"'
check "Open_MediaNameWithLineBreak_IsNotUploaded: a file the body never shows must not be published to GitHub" \
  '[ -n "$(uploaded_names)" ] && ! uploaded_names | grep -qxF -e "$injected_line"'

echo "a lookup of the open pull request that fails"
reset_fake_gh; write_body; printf '1\nthe lookup is refused\npr list\n' > "$FAKE_GH_DIR/fail"
publish lookup-fails main
check "Open_LookupFails_ExitsOne: the script cannot tell a new pull request from an update" \
  '[ "$(publish_code lookup-fails)" = "$failed_exit" ]'
check "Open_LookupFails_CreatesNoPullRequest: a create after a failed lookup could open a second pull request on the branch" \
  '[ -z "$(pull_request_field url)" ]'

echo "a pull request from a fork on a branch of the same name"
reset_fake_gh; write_body; seed_fork_pull_request
publish fork-alone main
check "Open_ForkPullRequestAlone_CreatesOurOwn: a fork's pull request on a branch of the same name is an outsider's, not this branch's" \
  '[ -n "$(pull_request_field url)" ] && [ "$(published fork-alone)" = "$(printf "$created_line" "$(pull_request_field url)")" ]'
check "Open_ForkPullRequestAlone_ForkBodyStaysAsItWas: an outsider's pull request must never carry this branch's verdict and evidence" \
  '[ -n "$fork_pull_request_body" ] && [ "$(fork_pull_request_field body)" = "$fork_pull_request_body" ]'

echo "a pull request from a fork beside our own"
reset_fake_gh; seed_pull_request "$(printf '## Summary\n\nEvidence shows inline.\n\n## Verification\n\n%s\n\nItem: %s\n' "$old_verdict" "$item")"
seed_fork_pull_request
publish fork-and-ours main
check "Open_ForkAndOurPullRequest_UpdatesOurs: only this repository's pull requests count, so a fork's leaves the lookup certain" \
  '[ -n "$(pull_request_field url)" ] && [ "$(published fork-and-ours)" = "$(printf "$updated_line" "$(pull_request_field url)")" ]'
check "Open_ForkAndOurPullRequest_OurBodyHoldsTheNewVerdict: the reviewer reads this verify's verdict in the branch's own pull request" \
  '[ -n "$new_verdict" ] && pull_request_field body | grep -qF -e "$new_verdict"'

echo "more images than gh takes in one call"
attach_limit="$(pr_publish_constant ATTACH_LIMIT)"
media_file_count=$((attach_limit + 1))
file_number_digits=3
first_media_name="$(printf "shot-%0${file_number_digits}d.png" 1)"
new_item many "  capture: 'sh $work/capture-many.sh'"
branch="$(git -C "$worktree" symbolic-ref --short HEAD)"
{ printf "evidence='%s/evidence'\nmedia_file_count='%s'\nfile_number_digits='%s'\n" "$reports" "$media_file_count" "$file_number_digits"
  cat <<'CAPTURE'
mkdir -p "$evidence"
python3 -I -c 'import os, sys
for file_number in range(1, int(sys.argv[2]) + 1):
    with open(os.path.join(sys.argv[1], "shot-%0*d.png" % (int(sys.argv[3]), file_number)), "w") as image:
        image.write("png bytes %d\n" % file_number)' "$evidence" "$media_file_count" "$file_number_digits"
CAPTURE
} > "$work/capture-many.sh"
commit_test_command true
write_proofs '[{"line": 1, "text": "the login screen shows", "grade": "live", "evidence": "evidence/'"$first_media_name"'"}]'
verify >/dev/null 2>&1
evidence_media_names() { (cd "$reports/evidence" && LC_ALL=C ls) | grep -F '.png'; }
reset_fake_gh; write_body
publish many main
check "Open_MoreMediaFilesThanOneCallTakes_EveryFileAttached: a file past gh's limit for one call still reaches the pull request" \
  '[ -n "$(uploaded_names)" ] && [ "$(uploaded_names)" = "$(evidence_media_names)" ]'
check "Open_MoreMediaFilesThanOneCallTakes_ExitsZero: gh refuses a call with more files than its limit, so a clean exit says no call carried more" \
  '[ "$(publish_code many)" = "$published_exit" ]'
check "Open_MoreMediaFilesThanOneCallTakes_BodyHasNoLocalReferenceLeft: a later batch must rewrite the references the first call left local" \
  'pull_request_field body | grep -qF -e "$asset_reference" && ! pull_request_field body | grep -qF -e "$local_reference"'

echo "a second batch whose first file does not upload"
extra_name="$(printf "shot-%0${file_number_digits}d.png" "$((media_file_count + 1))")"
printf 'extra png bytes\n' > "$reports/evidence/$extra_name"
second_batch_names="$(evidence_media_names | tail -n "+$media_file_count")"
reset_fake_gh; write_body; fail_upload_of "$(printf '%s\n' "$second_batch_names" | head -n 1)"
publish second-batch-fails main
rm -f "$reports/evidence/$extra_name"
check "Open_SecondBatchFails_NamesEveryFileOfIt: gh stops at the first failure, so no file of that batch reached the pull request" \
  '[ -n "$second_batch_names" ] && [ "$(not_uploaded second-batch-fails)" = "$second_batch_names" ]'
check "Open_SecondBatchFails_ExitsOne: a failed later batch leaves files off the pull request, so the pr step fails" \
  '[ "$(publish_code second-batch-fails)" = "$failed_exit" ]'

if [ "$fails" -eq 0 ]; then echo "pr-publish: ok"; else echo "pr-publish: $fails failed"; exit 1; fi
