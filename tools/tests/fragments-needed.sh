#!/bin/sh
# Tests tools/lib/fragments_needed.py, the check that a change to what a plugin ships carries a
# changelog fragment, on throwaway git repositories. Takes no argument. Exit 0 when every check
# passes, 1 on the first failure.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)"
. "$root/tools/lib/sandbox.sh"; sandbox_enter "$work" "$root/tools"
trap 'sandbox_close $?' EXIT

passes_exit=0
owes_exit=1
refused_exit=2
fragment_text="$(printf 'bump: patch\n\n- A change a user sees.')"
verify_command_template="$(python3 -I -c 'import json, sys; print(next(entry["command"] for entry in json.load(open(sys.argv[1]))["test"] if entry["name"] == "fragments"))' "$root/.standards/config.json")"

repository_seeded() {
  repository_folder="$(mktemp -d "$work/repository.XXXXXX")"
  git init -q -b main "$repository_folder"
  git -C "$repository_folder" config user.name "Fragments Suite"
  git -C "$repository_folder" config user.email "fragments-suite@example.invalid"
  for repository_plugin in flow meta standards; do
    repository_write "$repository_folder" "plugins/$repository_plugin/plugin.source.json" "{\"name\": \"$repository_plugin\", \"version\": \"1.0.0\"}"
    repository_write "$repository_folder" "plugins/$repository_plugin/skills/use/SKILL.md" "first"
  done
  repository_write "$repository_folder" plugins/meta/skills/map/assets/map.html "<p>first map</p>"
  mkdir -p "$repository_folder/tools/lib"
  cp "$root/tools/lib/fragments_needed.py" "$repository_folder/tools/lib/"
  repository_commit "$repository_folder" "chore: seed"
  git -C "$repository_folder" update-ref refs/remotes/origin/main main
  git -C "$repository_folder" switch -q -c work
  echo "$repository_folder"
}
repository_write() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" > "$1/$2"
}
repository_commit() {
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
}
repository_fragment() {
  repository_write "$1" "plugins/$2/changelog.d/$3.md" "$fragment_text"
}
repository_epic_merged_main() {
  repository_epic_folder="$(repository_seeded)"
  git -C "$repository_epic_folder" switch -q -c epic/1 main
  git -C "$repository_epic_folder" switch -q main
  repository_write "$repository_epic_folder" plugins/flow/skills/use/SKILL.md "flow on the default branch"
  repository_fragment "$repository_epic_folder" flow default-branch-change
  repository_commit "$repository_epic_folder" "feat(flow): a change with its fragment"
  git -C "$repository_epic_folder" rm -q plugins/flow/changelog.d/default-branch-change.md
  repository_write "$repository_epic_folder" plugins/flow/CHANGELOG.md "# flow"
  repository_write "$repository_epic_folder" plugins/flow/plugin.source.json '{"name": "flow", "version": "1.1.0"}'
  repository_commit "$repository_epic_folder" "release: flow 1.1.0"
  repository_write "$repository_epic_folder" plugins/meta/skills/use/SKILL.md "meta merged with no fragment"
  repository_commit "$repository_epic_folder" "feat(meta): a change that merged before the check"
  git -C "$repository_epic_folder" update-ref refs/remotes/origin/main main
  git -C "$repository_epic_folder" switch -q epic/1
  git -C "$repository_epic_folder" tag epic-tip-before-merge
  git -C "$repository_epic_folder" merge -q --no-ff -m "chore: merge main into epic/1" main
  echo "$repository_epic_folder"
}
outcome() {
  outcome_repository="$1"; shift
  outcome_status=0
  (cd "$outcome_repository" && python3 -I tools/lib/fragments_needed.py "$@") > "$work/output" 2>&1 || outcome_status=$?
  outcome_described "$outcome_status"
}
verify_outcome() {
  verify_outcome_status=0
  (cd "$1" && sh -c "$2") > "$work/output" 2>&1 || verify_outcome_status=$?
  outcome_described "$verify_outcome_status"
}
outcome_described() {
  outcome_described_named=""
  for outcome_described_plugin in flow meta standards; do
    if grep -qw -- "$outcome_described_plugin" "$work/output"; then outcome_described_named="$outcome_described_named $outcome_described_plugin"; fi
  done
  echo "exit $1, names:${outcome_described_named:- none}"
}
verify_command_with_base() {
  printf '%s\n' "$verify_command_template" | sed "s/{verify_base}/$1/g"
}
expect() { [ "$2" = "$3" ] || { echo "FAIL $1"; echo "  expected: $3"; echo "  actual:   $2"; cat "$work/output"; exit 1; }; echo "ok $1"; }

repository="$(repository_seeded)"
repository_write "$repository" plugins/flow/skills/use/SKILL.md "a shipped change"
repository_commit "$repository" "feat(flow): a shipped change"
expect 'ShippedFileWithoutFragment_Fails because a plugin change with no fragment never reaches a release' \
  "$(outcome "$repository" main origin/main)" "exit $owes_exit, names: flow"
outcome "$repository" main origin/main > /dev/null
expect 'ShippedFileWithoutFragment_NamesThePluginAndTheFragmentPath because the author must see what to add' \
  "$(grep -cF 'plugins/flow/changelog.d/' "$work/output")" 1

repository="$(repository_seeded)"
repository_write "$repository" plugins/flow/skills/use/SKILL.md "a shipped flow change"
repository_write "$repository" plugins/standards/skills/use/SKILL.md "a shipped standards change"
repository_fragment "$repository" flow flow-change
repository_fragment "$repository" standards standards-change
repository_commit "$repository" "feat: change flow and standards"
expect 'FragmentForEachChangedPlugin_Passes because every changed plugin carries its fragment' \
  "$(outcome "$repository" main origin/main)" "exit $passes_exit, names: none"

repository="$(repository_seeded)"
repository_write "$repository" plugins/flow/skills/use/SKILL.md "a shipped flow change"
repository_write "$repository" plugins/standards/skills/use/SKILL.md "a shipped standards change"
repository_fragment "$repository" flow flow-change
repository_commit "$repository" "feat: change flow and standards"
expect 'TwoPluginsChangedOneFragment_NamesOnlyTheOtherPlugin because a fragment pays only for its own plugin' \
  "$(outcome "$repository" main origin/main)" "exit $owes_exit, names: standards"

repository="$(repository_seeded)"
repository_write "$repository" plugins/flow/skills/use/SKILL.md "a shipped flow change"
repository_fragment "$repository" standards standards-change
repository_commit "$repository" "feat(flow): a change with a fragment for another plugin"
expect 'FragmentForAnotherPlugin_NamesTheChangedPlugin because a fragment raises only the plugin whose folder holds it' \
  "$(outcome "$repository" main origin/main)" "exit $owes_exit, names: flow"

repository="$(repository_seeded)"
repository_write "$repository" plugins/flow/skills/use/SKILL.md "a shipped flow change"
repository_write "$repository" plugins/flow/changelog.d/flow-change.txt "$fragment_text"
repository_commit "$repository" "feat(flow): a change with a fragment that is not markdown"
expect 'ChangelogFileNotMarkdown_Fails because the release folds only the markdown fragments' \
  "$(outcome "$repository" main origin/main)" "exit $owes_exit, names: flow"

repository="$(repository_seeded)"
repository_write "$repository" plugins/shared/lib.sh "a helper no plugin manifest claims"
repository_commit "$repository" "chore: a folder under plugins that is no plugin"
expect 'FolderWithoutPluginSource_Passes because a folder with no plugin.source.json is never released' \
  "$(outcome "$repository" main origin/main)" "exit $passes_exit, names: none"

repository="$(repository_seeded)"
repository_write "$repository" plugins/flow/tests/board.sh "a flow suite"
repository_write "$repository" plugins/flow/skills/use/SKILL.md "a shipped flow change"
repository_commit "$repository" "feat(flow): a shipped change with its suite"
expect 'TestsBesideShippedFileWithoutFragment_Fails because the test exemption must not hide a shipped change' \
  "$(outcome "$repository" main origin/main)" "exit $owes_exit, names: flow"

repository="$(repository_seeded)"
repository_write "$repository" plugins/flow/tests/board.sh "a flow suite"
repository_write "$repository" plugins/standards/hooks/tests/run.sh "a hook suite"
repository_write "$repository" plugins/meta/app/daemon/test/server.test.ts "a daemon test"
repository_write "$repository" plugins/meta/evals/map.json "an eval case"
repository_commit "$repository" "test: tests and evals only"
expect 'OnlyTestsAndEvalsChanged_Passes because tests and evals change nothing a user installs' \
  "$(outcome "$repository" main origin/main)" "exit $passes_exit, names: none"

repository="$(repository_seeded)"
repository_write "$repository" plugins/flow/skills/use/SKILL.md "a shipped flow change"
repository_fragment "$repository" flow flow-change
repository_write "$repository" plugins/meta/skills/map/assets/map.html "<p>regenerated map</p>"
repository_commit "$repository" "feat(flow): a change that regenerates the map"
expect 'OnlyMetaMapRegenerated_Passes because every generate rewrites the map whatever plugin changed' \
  "$(outcome "$repository" main origin/main)" "exit $passes_exit, names: none"

repository="$(repository_seeded)"
git -C "$repository" switch -q main
repository_write "$repository" plugins/flow/skills/use/SKILL.md "a shipped flow change"
repository_fragment "$repository" flow flow-change
repository_commit "$repository" "feat(flow): a change with its fragment"
git -C "$repository" update-ref refs/remotes/origin/main main
git -C "$repository" switch -q -C work main
git -C "$repository" rm -q plugins/flow/changelog.d/flow-change.md
repository_write "$repository" plugins/flow/CHANGELOG.md "# flow"
repository_write "$repository" plugins/flow/plugin.source.json '{"name": "flow", "version": "1.1.0"}'
repository_commit "$repository" "release: flow 1.1.0"
expect 'ReleaseFoldCommit_Passes because the release folds the fragments a plugin change carried' \
  "$(outcome "$repository" main origin/main)" "exit $passes_exit, names: none"

repository="$(repository_epic_merged_main)"
expect 'DefaultBranchMergedIntoEpicBranch_Passes because commits from the default branch are not the epic work' \
  "$(outcome "$repository" "$(git -C "$repository" rev-parse epic-tip-before-merge)" origin/main)" "exit $passes_exit, names: none"

repository="$(repository_epic_merged_main)"
repository_write "$repository" plugins/standards/skills/use/SKILL.md "an epic child change"
repository_commit "$repository" "feat(standards): an epic child with no fragment"
expect "EpicChildWithoutFragment_Fails because excluding the default branch must not hide the epic's own work" \
  "$(outcome "$repository" "$(git -C "$repository" rev-parse epic-tip-before-merge)" origin/main)" "exit $owes_exit, names: standards"

repository="$(repository_seeded)"
repository_write "$repository" plugins/flow/skills/use/SKILL.md "a shipped change"
repository_commit "$repository" "feat(flow): a shipped change"
expect 'UnavailableBaseWithoutFragment_StillFails because a refused base widens the comparison to the default branch' \
  "$(outcome "$repository" unavailable origin/main)" "exit $owes_exit, names: flow"
expect 'OnlyUnavailableBase_ExitsTwo because with no ref left there is nothing to compare with' \
  "$(outcome "$repository" unavailable)" "exit $refused_exit, names: none"
expect 'UnknownRef_ExitsTwo because a ref git cannot resolve must stop the check, never pass it' \
  "$(outcome "$repository" no-such-branch origin/main)" "exit $refused_exit, names: none"

repository="$(repository_seeded)"
repository_write "$repository" plugins/flow/skills/use/SKILL.md "a shipped change"
repository_commit "$repository" "feat(flow): a shipped change"
expect 'VerifyCommandOnAPluginChangeWithoutFragment_Fails because verify runs the same check before a PR exists' \
  "$(verify_outcome "$repository" "$(verify_command_with_base "$(git -C "$repository" rev-parse main)")")" "exit $owes_exit, names: flow"

repository="$(repository_seeded)"
repository_write "$repository" plugins/flow/skills/use/SKILL.md "a shipped change"
repository_fragment "$repository" flow flow-change
repository_commit "$repository" "feat(flow): a shipped change with its fragment"
expect 'VerifyCommandOnAPluginChangeWithFragment_Passes because verify must not fail a change that carries its fragment' \
  "$(verify_outcome "$repository" "$(verify_command_with_base "$(git -C "$repository" rev-parse main)")")" "exit $passes_exit, names: none"
