# epic_base.sh: the health job keeps an approved epic's branch up with its base. Sourced by
# scripts/steward.sh, whose health_epic_branch calls health_epic_base for an epic whose branch is
# on the remote. The base is the one a new epic branch would start from (fetch_epic_start in
# lib/base.sh), read only as the remote holds it. Once the epic branch is more than
# jobs.health.behind_base commits behind it, the base is merged in and pushed with no worktree:
# git merge-tree finds the merged tree and git commit-tree makes the merge commit, the base its
# second parent even where a fast-forward would do, so the epic's own history stays first. The
# push is never forced: a child PR merged in the meantime wins, and the next run tries again.
# A merge that conflicts changes nothing; it is said and notified once per base and set of
# conflicted files, which the owner resolves by hand. A refused push and a merge git cannot make
# are each said once, with no notification. Left alone, and said nothing of: an epic in a
# repository with no remote, one the tracker cannot read, a base that does not resolve or is not
# on the remote, and a base that is the task branch of the epic's parent, whose work reaches the
# epic branch through its PR. A dry run fetches no branch and pushes nothing. Sourced, never run.
# shellcheck disable=SC2154 # scripts/steward.sh, which sources it, sets dry, have_remote and behind_base
EPIC_BASE_KEY_PREFIX=epic-base-
EPIC_BASE_PUSH_KEY_PREFIX=epic-push-
EPIC_BASE_MERGE_CONFLICTED=1

epic_base_fetch_branch() {
  [ -n "$1" ] || return 1
  epic_base_resolved="$(fetch_epic_start "$1")" || return 1
  epic_base_parent="$(json_get "$1" parent)"
  if [ -n "$epic_base_parent" ] && [ "$(parent_branch "$epic_base_parent")" = "$epic_base_resolved" ]; then return 1; fi
  printf '%s' "$epic_base_resolved"
}

epic_base_remote_tip() { git -C "$1" rev-parse -q --verify "refs/remotes/origin/$2^{commit}"; }

epic_base_conflicted_files() { sed 1d | LC_ALL=C sort -u | awk '{ printf "%s%s", separator, $0; separator = ", " }'; }

epic_base_say_conflict() {
  health_changed "$EPIC_BASE_KEY_PREFIX$(item_slug "$1")" "$2 $4" || return 0
  epic_base_conflict_branch="$(epic_branch "$1")"
  if [ "$dry" -eq 1 ]; then health_say "$1" "would say $epic_base_conflict_branch conflicts with origin/$2 in: $4"; return 0; fi
  epic_base_conflict_text="$epic_base_conflict_branch is $3 commits behind origin/$2 and its merge conflicts in: $4; nothing was pushed, merge it by hand"
  health_say "$1" "$epic_base_conflict_text"
  health_notify "$epic_base_conflict_text"
}

epic_base_say_unmerged() {
  health_changed "$EPIC_BASE_KEY_PREFIX$(item_slug "$1")" "$2: $3" || return 0
  health_say "$1" "could not merge origin/$2 into $(epic_branch "$1"): $3"
}

epic_base_say_push_refused() {
  health_changed "$EPIC_BASE_PUSH_KEY_PREFIX$(item_slug "$1")" "$2" || return 0
  health_say "$1" "could not push the merge of origin/$2 into $(epic_branch "$1"); the next run tries again"
}

epic_base_take_merge() {
  epic_base_epic_branch="$(epic_branch "$1")"
  epic_base_merge_text="origin/$3 into $epic_base_epic_branch ($4 commits behind)"
  if [ "$dry" -eq 1 ]; then health_say "$1" "would merge $epic_base_merge_text"; return 0; fi
  epic_base_commit="$(git -C "$2" commit-tree "$5" -p "$6" -p "$7" -m "chore: merge $3 into $epic_base_epic_branch" 2>/dev/null)" \
    || { epic_base_say_unmerged "$1" "$3" "git commit-tree failed"; return 0; }
  git -C "$2" push -q origin "$epic_base_commit:refs/heads/$epic_base_epic_branch" >/dev/null 2>&1 \
    || { epic_base_say_push_refused "$1" "$3"; return 0; }
  fetch_base "$epic_base_epic_branch"
  health_cleared "$EPIC_BASE_KEY_PREFIX$(item_slug "$1")"
  health_cleared "$EPIC_BASE_PUSH_KEY_PREFIX$(item_slug "$1")"
  health_say "$1" "merged $epic_base_merge_text"
}

epic_base_merge() {
  epic_base_epic_tip="$(epic_base_remote_tip "$2" "$(epic_branch "$1")")" || return 0
  epic_base_base_tip="$(epic_base_remote_tip "$2" "$3")" || return 0
  epic_base_merged="$(git -C "$2" merge-tree --write-tree --name-only --no-messages "$epic_base_epic_tip" "$epic_base_base_tip" 2>/dev/null)"
  case $? in
    0) epic_base_take_merge "$1" "$2" "$3" "$4" "$(printf '%s\n' "$epic_base_merged" | sed -n 1p)" "$epic_base_epic_tip" "$epic_base_base_tip" ;;
    "$EPIC_BASE_MERGE_CONFLICTED") epic_base_say_conflict "$1" "$3" "$4" "$(printf '%s\n' "$epic_base_merged" | epic_base_conflicted_files)" ;;
    *) epic_base_say_unmerged "$1" "$3" "git merge-tree failed" ;;
  esac
}

health_epic_base() {
  [ "$have_remote" -eq 1 ] || return 0
  epic_base_base_branch="$(epic_base_fetch_branch "$(adapter read "$1" 2>/dev/null)")" || return 0
  epic_base_repository="$(flow_repository)"
  [ "$dry" -eq 1 ] || { fetch_base "$(epic_branch "$1")"; fetch_base "$epic_base_base_branch"; }
  epic_base_behind="$(git -C "$epic_base_repository" rev-list --count "refs/remotes/origin/$(epic_branch "$1")..refs/remotes/origin/$epic_base_base_branch" 2>/dev/null)" || return 0
  if [ "$epic_base_behind" -le "$behind_base" ]; then health_cleared "$EPIC_BASE_KEY_PREFIX$(item_slug "$1")"; return 0; fi
  epic_base_merge "$1" "$epic_base_repository" "$epic_base_base_branch" "$epic_base_behind"
}
