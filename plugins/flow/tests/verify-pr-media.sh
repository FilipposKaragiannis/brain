#!/bin/sh
# verify-pr-media.sh: pr-report.sh shows each image and video under evidence/ in the Verification
# section as a reference under the Evidence title, alone in its paragraph and with its name
# percent-encoded, a live proof of one says it is shown below, the section gains no heading, a name
# with a line break adds no line of its own, and a link is never referenced. The report comes from
# the real verify, on the local adapter in a throwaway repo, from a proofs file and a capture the
# suite writes.
# Exit 0 when every check passes, 1 on any failure. run.sh runs it.
# shellcheck disable=SC2034,SC2154 # the fixtures this sources set and read these names, and check reads them inside its quoted conditions
. "$(dirname "$0")/_base_fixture.sh"
. "$plugin/../../tools/lib/sandbox.sh"; sandbox_enter "$work" "$plugin"
trap 'sandbox_close $?' EXIT
. "$here/_verify_fixture.sh"

section_heading_count=1
image_reference='![shot.png](./evidence/shot.png)'
video_reference='![run.mp4](./evidence/run.mp4)'
spaced_reference='![my shot.png](./evidence/my%20shot.png)'
image_proof_line=1
injected_line="Resolves #1"
line_break_name="$(printf 'shot\n%s\nend.png' "$injected_line")"
pr_report_constant() { python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import _pr_report; print(getattr(_pr_report, sys.argv[2]))' "$plugin/scripts" "$1"; }
evidence_title="$(pr_report_constant EVIDENCE_TITLE)"
shown_below="$(pr_report_constant SHOWN_BELOW)"
commit_test_command() {
  mkdir -p "$worktree/.standards" && printf '{"test": "%s"}\n' "$1" > "$worktree/.standards/config.json"
  git -C "$worktree" add .standards/config.json && git -C "$worktree" commit -qm "test command"
}
write_proofs() { printf '{"head": "%s", "proofs": %s}\n' "$(git -C "$worktree" rev-parse HEAD)" "$1" > "$reports/proofs.json"; }
rendered() { cat "$work/media.out"; }
section_row() { awk -v line="$1" 'index($0, "| " line " |") == 1' "$work/media.out"; }
# paragraph_of <line>: the lines of the paragraph that holds the line, blank lines being its bounds.
paragraph_of() { awk -v wanted="$1" '$0 == "" { if (found) exit; paragraph = ""; next } { paragraph = paragraph $0 "\n" } $0 == wanted { found = 1 } END { if (found) printf "%s", paragraph }' "$work/media.out"; }

echo "image, video, spaced, text and linked captures"
new_item media "  capture: 'sh $work/capture-media.sh'"
{ printf "evidence='%s/evidence'\noutside='%s/outside.png'\nline_break_name='%s'\n" "$reports" "$work" "$line_break_name"
  cat <<'CAPTURE'
mkdir -p "$evidence"
printf 'png bytes\n' > "$evidence/shot.png"
printf 'mp4 bytes\n' > "$evidence/run.mp4"
printf 'png bytes\n' > "$evidence/my shot.png"
printf 'png bytes\n' > "$evidence/$line_break_name"
printf 'the login page greeted the owner\n' > "$evidence/notes.txt"
printf 'png bytes\n' > "$outside"
ln -s "$outside" "$evidence/linked.png"
CAPTURE
} > "$work/capture-media.sh"
commit_test_command true
write_proofs '[{"line": 1, "text": "the login screen shows", "grade": "live", "evidence": "evidence/shot.png"}]'
verify >/dev/null 2>&1
"$plugin/scripts/pr-report.sh" "$reports" > "$work/media.out" 2> "$work/media.err"

check "Render_ImageEvidence_ShowsAsAnImageReference: a reviewer sees the screenshot in the pull request once gh swaps in its asset URL" \
  'rendered | grep -qxF -e "$image_reference"'
check "Render_VideoEvidence_ReferenceStandsAloneInItsParagraph: GitHub plays a video only when its URL is the whole paragraph" \
  '[ "$(paragraph_of "$video_reference")" = "$video_reference" ]'
check "Render_EvidenceNameWithSpace_ReferenceIsPercentEncoded: a bare space ends a Markdown destination, so gh would find no file to swap" \
  'rendered | grep -qxF -e "$spaced_reference"'
check "Render_LiveMediaProof_CellSaysShownBelow: a reviewer finds the capture that proves the line below the table" \
  '[ -n "$shown_below" ] && section_row "$image_proof_line" | grep -qF -e "\`shot.png\`$shown_below"'
check "Render_MediaEvidence_ShowsUnderTheEvidenceTitle: a reviewer finds the captures under their own title in the section" \
  '[ -n "$evidence_title" ] && rendered | grep -qxF -e "$evidence_title"'
check "Render_MediaEvidence_HasNoHeadingOfItsOwn: a second heading would end the section, so an update would leave the media behind" \
  '[ "$(rendered | grep -c "^## ")" -eq "$section_heading_count" ]'
check "Render_MediaNameWithLineBreak_AddsNoLineOfItsOwn: a line break in a file name would put a line of its own in the body, such as a closing keyword" \
  '[ -n "$(rendered)" ] && ! rendered | grep -qxF -e "$injected_line"'
check "Render_LinkedMediaFile_IsNotReferenced: a link could publish a file from outside the evidence folder" \
  'rendered | grep -qxF -e "$image_reference" && ! rendered | grep -qF linked.png'

if [ "$fails" -eq 0 ]; then echo "verify-pr-media: ok"; else echo "verify-pr-media: $fails failed"; exit 1; fi
