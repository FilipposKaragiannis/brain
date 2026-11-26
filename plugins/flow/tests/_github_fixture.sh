# _github_fixture.sh: the fake gh the GitHub checks run on: FAKE_GH_DIR with four issues of acme/widgets,
# gh first on PATH through $work/bin, and the repo's config on the github adapter. Takes $P and
# $work, and runs in the repo _flow_setup.sh made. Sourced after _flow_setup.sh, never run.
export FAKE_GH_DIR="$work/gh"; mkdir -p "$FAKE_GH_DIR"; cp "$P/tests/_fake_gh.py" "$FAKE_GH_DIR/"
cat > "$FAKE_GH_DIR/issues.json" <<'JSON'
{"issues": [
  {"number": 10, "title": "Epic", "body": "", "state": "OPEN", "labels": ["epic", "size:L"], "url": "https://gh/10"},
  {"number": 11, "title": "Task one", "body": "## Acceptance\n- x", "state": "OPEN", "labels": ["size:S"], "url": "https://gh/11", "blocked_by": []},
  {"number": 12, "title": "Task two", "body": "", "state": "OPEN", "labels": ["size:M", "status:blocked"], "url": "https://gh/12", "blocked_by": [11]},
  {"number": 13, "title": "Old", "body": "", "state": "CLOSED", "labels": [], "url": "https://gh/13"}
]}
JSON
mkdir -p "$work/bin" && ln -s "$P/tests/fake-gh.sh" "$work/bin/gh"
export PATH="$work/bin:$PATH"
printf 'adapters:\n  default: github\nbase: main\ngithub:\n  repo: acme/widgets\npool:\n  - ../wt-1\n  - ../wt-2\nnotify:\n  desktop: false\n' > .flow/config.yaml
github_state_marker() {
  found_state_marker="$(sed -n 's/^STATE_MARKER="\(.*\)"$/\1/p' "$P/adapters/github/_gh.sh")"
  [ -n "$found_state_marker" ] || { echo "_github_fixture: no STATE_MARKER in $P/adapters/github/_gh.sh" >&2; return 1; }
  printf '%s\n' "$found_state_marker"
}
