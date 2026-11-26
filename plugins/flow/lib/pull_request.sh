# The PR of an item: linked on its tracker and written to its record by the one function the
# orchestrator scripts call, and what a pr step done with no PR recorded leaves on its task branch,
# one word for the caller to act on: found <url> (a PR whose head is the branch), nothing-to-merge,
# unopened (changes and no PR) or unanswered (changes, and gh could not say whether a PR exists).
# Sourced after lib/flow.sh by scripts/advance.sh, scripts/epic-pr.sh and scripts/steward.sh.

# link_and_record_pull_request <item> <url> <host>: the tracker is told of the PR (adapter link-pr),
# a refusal only warned, then the record takes pr and pr_host. The host is kept only when it is
# claude or codex. Exit record_set's code.
link_and_record_pull_request() (
  [ $# -eq 3 ] || die "usage: link_and_record_pull_request <item> <url> <host>" "$EXIT_USAGE"
  adapter link-pr "$1" "$2" </dev/null >/dev/null || echo "flow: the tracker of $1 did not take $2" >&2
  case "$3" in claude|codex) linked_host="$3" ;; *) linked_host="" ;; esac
  record_set "$1" "pr=$2" "pr_host=$linked_host" </dev/null
)

# pull_request_on_branch <home> <branch>: the URL of a PR whose head is the branch, or nothing; fails
# when gh cannot answer. The same lookup as the sweep's.
pull_request_on_branch() {
  github_repository="$(cfg github.repo)"
  pull_requests_found="$(cd "$(dirname "$1")" && gh pr list ${github_repository:+-R "$github_repository"} --head "$2" --state all --json url 2>/dev/null)" || return 1
  json_get "$pull_requests_found" 0.url
}

# nothing_to_merge <worktree> <base>: true when the worktree has no uncommitted change outside .flow
# and its HEAD no diff against the base, at its local tip when a pool claim holds it, as the claim
# took it.
nothing_to_merge() {
  base_reference="$2"
  [ -n "$("$FLOW_PLUGIN/scripts/steward.sh" owner "$2")" ] || ! git -C "$1" show-ref --verify --quiet "refs/remotes/origin/$2" || base_reference="origin/$2"
  uncommitted_changes="$(git -C "$1" status --porcelain -- . ":!.flow" 2>/dev/null)" || return 1
  [ -z "$uncommitted_changes" ] && git -C "$1" diff --quiet "$base_reference...HEAD" -- 2>/dev/null
}

# settlement_without_pull_request <worktree> <base> <outcome>
settlement_without_pull_request() {
  if nothing_to_merge "$1" "$2"; then printf nothing-to-merge; else printf '%s' "$3"; fi
}

# pull_request_settlement <home> <worktree> <branch> <base>: the outcome word for the branch. A base
# that is the branch itself would always show nothing to merge, so it is unopened.
pull_request_settlement() {
  [ "$3" != "$4" ] || { printf unopened; return 0; }
  branch_pull_request="$(pull_request_on_branch "$1" "$3")" || { settlement_without_pull_request "$2" "$4" unanswered; return 0; }
  [ -z "$branch_pull_request" ] || { printf 'found %s' "$branch_pull_request"; return 0; }
  settlement_without_pull_request "$2" "$4" unopened
}
