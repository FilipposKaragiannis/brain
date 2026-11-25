#!/bin/sh
# epic-pr.sh <epic> <reports> [<summary>]: the pull request that brings an epic's work into the
# branch the epic started from. Prints its URL and records it on the epic (link-pr).
# The PR is a GitHub PR on the origin, from the epic branch (epic/<n>) into the epic's start
# (fetch_epic_start in lib/base.sh: an epic branch above it, a base: line in its body, else the
# config base), whatever tracker holds the epic. An open PR from that branch is taken as it is.
# A new one is titled as the epic and its body holds the house body's Summary and Evidence: the
# summary given and <reports>/verify.md, the closeout's report.
# Prints nothing, exit 0, when there is nothing to merge: the repository has no origin, the
# remote answers that it has no epic branch, or the epic branch holds no commit its start lacks.
# Exit 1, with why on stderr, when the remote cannot be asked for the epic branch or either
# branch cannot be fetched (unmerged work may sit on the epic branch), the epic's start does not
# resolve or is not on the remote, the two branches cannot be compared or gh refuses; exit 2 on a
# bad argument.
. "$(dirname "$0")/../lib/flow.sh"
. "$FLOW_PLUGIN/lib/base.sh"
[ $# -ge 2 ] || die "usage: epic-pr.sh <epic> <reports> [<summary>]" 2
epic="$1"; reports="$2"; summary="${3:-}"
repository="$(flow_repository)"
github_repository="$(cfg github.repo)"
LS_REMOTE_NO_MATCH=2

on_github() { (cd "$repository" && gh "$@" ${github_repository:+-R "$github_repository"}); }

remote_holds_branch() {
  git -C "$repository" ls-remote --exit-code --heads origin "$1" >/dev/null 2>&1; asked=$?
  [ "$asked" -eq 0 ] || [ "$asked" -eq "$LS_REMOTE_NO_MATCH" ] || die "$epic: the remote could not be asked for $1, so its work may still be unmerged"
  return "$asked"
}

fetch_fresh() {
  git -C "$repository" fetch -q origin "+refs/heads/$1:refs/remotes/origin/$1" >/dev/null 2>&1 || die "$epic: $1 could not be fetched, so what the remote holds of it is not known"
}

open_pull_request() {
  on_github pr list --head "$1" --state open --json url 2>/dev/null \
    | cached_python3 -I -c 'import json, sys; listed = json.load(sys.stdin); print(listed[0]["url"] if listed else "")' 2>/dev/null
}

pull_request_body() {
  echo "## Summary"
  echo
  echo "Every task of $epic is closed. This brings \`$1\` into \`$2\`: the epic's whole work, verified together at closeout."
  [ -z "$summary" ] || { echo; printf '%s\n' "$summary"; }
  echo
  echo "## Evidence"
  echo
  if [ -s "$reports/verify.md" ]; then cat "$reports/verify.md"; else echo "The closeout wrote no verify report."; fi
  case "$epic" in gh#*) echo; echo "Closes #${epic#gh#}" ;; esac
}

new_pull_request() {
  body_file="$(mktemp)"
  pull_request_body "$1" "$2" > "$body_file"
  created="$(on_github pr create --base "$2" --head "$1" --title "$(json_get "$epic_record" title)" --body-file "$body_file")"; created_code=$?
  rm -f "$body_file"
  [ "$created_code" -eq 0 ] && printf '%s\n' "$created" | tail -n 1
}

git -C "$repository" remote get-url origin >/dev/null 2>&1 || exit 0
epic_record="$(adapter read "$epic")" || die "cannot read $epic"
[ "$(json_get "$epic_record" kind)" = epic ] || die "$epic is no epic" 2
head_branch="$(epic_branch "$epic")"
remote_holds_branch "$head_branch" || exit 0
fetch_fresh "$head_branch"
target_branch="$(fetch_epic_start "$epic_record")" || die "$epic: $target_branch"
remote_holds_branch "$target_branch" || die "$epic: its base $target_branch is not on the remote, so $head_branch has no branch to merge into"
fetch_fresh "$target_branch"
ahead="$(git -C "$repository" rev-list --count "refs/remotes/origin/$target_branch..refs/remotes/origin/$head_branch" 2>/dev/null)" \
  || die "$epic: git could not compare $head_branch with $target_branch"
[ "$ahead" -gt 0 ] || exit 0
pull_request="$(open_pull_request "$head_branch")"
[ -n "$pull_request" ] || pull_request="$(new_pull_request "$head_branch" "$target_branch")"
[ -n "$pull_request" ] || die "$epic: gh could not open the pull request: gh pr create --base $target_branch --head $head_branch"
adapter link-pr "$epic" "$pull_request" >/dev/null || echo "epic-pr: could not record $pull_request on $epic" >&2
printf '%s\n' "$pull_request"
