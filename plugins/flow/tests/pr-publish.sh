#!/bin/sh
# pr-publish.sh: the script that opens the pull request of the pr step. With no PR on the branch,
# open creates one from <reports>/pr-body.md with the Verification section swapped in and every
# image and video under evidence/ attached, so the body's references become asset URLs; it exits
# 0 with the URL, a --draft opens a draft, a text capture is never attached, and a base gh would
# read as an option is refused as a usage error. The report comes from the real verify, on the
# local adapter in a throwaway repo, and gh is the fake one.
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
usage_exit=2
pull_request_title="Image evidence renders inline"
base_gh_reads_as_an_option="--web"
local_reference='](./evidence/'
pr_publish_constant() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import _pr_publish; print(getattr(_pr_publish, sys.argv[2]))' "$plugin/scripts" "$1"; }
created_line="$(pr_publish_constant CREATED_LINE)"
commit_test_command() {
  mkdir -p "$worktree/.standards" && printf '{"test": "%s"}\n' "$1" > "$worktree/.standards/config.json"
  git -C "$worktree" add .standards/config.json && git -C "$worktree" commit -qm "test command"
}
write_proofs() { printf '{"head": "%s", "proofs": %s}\n' "$(git -C "$worktree" rev-parse HEAD)" "$1" > "$reports/proofs.json"; }
# reset_fake_gh: a fake GitHub that holds no pull request and no uploaded file.
reset_fake_gh() { printf '{"issues": []}\n' > "$FAKE_GH_DIR/issues.json"; : > "$FAKE_GH_DIR/calls.log"; }
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
published() { cat "$work/$1.out"; }
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

if [ "$fails" -eq 0 ]; then echo "pr-publish: ok"; else echo "pr-publish: $fails failed"; exit 1; fi
