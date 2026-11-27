# _pr_publish_fixture.sh: the fixture pr-publish.sh and pr-refresh.sh source, on top of
# _verify_fixture.sh: the fake gh first on PATH, its state readers and writers, a committed test
# command, a proofs file, the body the pr-creator writes, and a run of pr-publish.sh open with its
# output kept. Sourced after _verify_fixture.sh, never run.
# shellcheck disable=SC2034,SC2154 # the suite and the fixtures before this one set and read these names
export FAKE_GH_DIR="$work/gh"
mkdir -p "$FAKE_GH_DIR" "$work/github" && cp "$plugin/tests/_fake_gh.py" "$FAKE_GH_DIR/"
ln -s "$plugin/tests/fake-gh.sh" "$work/github/gh"
PATH="$work/github:$PATH"; export PATH

published_exit=0
failed_exit=1
usage_exit=2
pull_request_title="Image evidence renders inline"
local_reference='](./evidence/'
asset_reference='](https://gh/assets/'
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
fork_pull_request_url="https://gh/pull/92"
fork_pull_request_body="$(printf '## Summary\n\nA change from a fork.')"
# seed_fork_pull_request: the fake GitHub also holds an open pull request from a fork whose head has the branch's name.
seed_fork_pull_request() {
  python3 -c 'import json,sys; state = json.load(open(sys.argv[1])); state["forks"] = [{"number": 92, "state": "OPEN", "url": sys.argv[2], "headRefName": sys.argv[3], "baseRefName": "main", "body": sys.argv[4]}]; json.dump(state, open(sys.argv[1], "w"))' \
    "$FAKE_GH_DIR/issues.json" "$fork_pull_request_url" "$branch" "$fork_pull_request_body"
}
fork_pull_request_field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("forks", [{}])[0].get(sys.argv[2], ""))' "$FAKE_GH_DIR/issues.json" "$1"; }
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
# not_uploaded <name>: the evidence names the run <name> said were not uploaded, one per line.
not_uploaded() { grep -F -e "$not_uploaded_prefix" "$work/$1.err" | cut -c "$((${#not_uploaded_prefix} + 1))-"; }
publish_code() { cat "$work/$1.code"; }
pull_request_field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pr", {}).get(sys.argv[2], ""))' "$FAKE_GH_DIR/issues.json" "$1"; }
# uploaded_names: the name under evidence/ of each file the fake GitHub holds, one per line, sorted.
uploaded_names() { python3 -c 'import json,os,sys; print("\n".join(sorted(os.path.relpath(path, sys.argv[2]) for path in json.load(open(sys.argv[1])).get("assets", []))))' "$FAKE_GH_DIR/issues.json" "$reports/evidence"; }
report_verdict() { "$plugin/scripts/pr-report.sh" "$reports" | grep -m 1 -F 'Verdict: '; }
