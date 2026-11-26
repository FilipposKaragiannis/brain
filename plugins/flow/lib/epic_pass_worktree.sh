# epic_pass_worktree.sh: the worktree a comments pass on an epic's pull request works in. The epic
# holds no claim once its closeout is done, so no worktree has its branch, and the session needs
# one to commit in: a sandboxed one commits only in the folder it starts in. The pass claims a pool
# worktree on the epic branch at the tip the remote holds (steward.sh claim --branch); with the
# pool full, or the branch checked out elsewhere, a temporary worktree detached at that tip
# (steward.sh tmp tip). The worktree goes once the pass ends, unless it holds work the remote
# lacks, uncommitted or unpushed: then it stays, so the next pass continues from it. A pool claim
# released with unpushed commits would leave the local epic branch ahead of the remote, which every
# later claim of it refuses. The job records the worktree a pass made in a file of its own, as no
# claim tells a pass's claim from a closeout's, and lets go of only what that file names.
# Sourced by jobs/comments.sh after lib/flow.sh and lib/base.sh, never run.
# shellcheck disable=SC2154 # lib/base.sh, sourced first, sets the claim exit codes

epic_pass_worktree() {
  [ -n "$1" ] || return 0
  epic_pass_worktree_kept="$(epic_pass_kept_worktree "$1" "$2")" && { printf '%s' "$epic_pass_worktree_kept"; return 0; }
  [ "$3" = "$4" ] || return 0
  epic_pass_worktree_item_data="$(adapter read "$1" 2>/dev/null)"
  [ "$(json_get "$epic_pass_worktree_item_data" kind)" = epic ] || return 0
  epic_pass_make_worktree "$1" "$epic_pass_worktree_item_data"
}

epic_pass_kept_worktree() {
  epic_pass_kept_worktree_path="$(cat "$2" 2>/dev/null)"
  [ -n "$epic_pass_kept_worktree_path" ] && [ -d "$epic_pass_kept_worktree_path" ] || return 1
  epic_pass_temporary "$epic_pass_kept_worktree_path" \
    || [ "$("$FLOW_PLUGIN/scripts/steward.sh" find "$1" 2>/dev/null)" = "$epic_pass_kept_worktree_path" ] || return 1
  printf '%s' "$epic_pass_kept_worktree_path"
}

epic_pass_make_worktree() {
  epic_pass_make_worktree_branch="$(epic_branch "$1")"
  epic_pass_make_worktree_base="$(state_get "$2" base)"
  base_name_valid "$epic_pass_make_worktree_base" || epic_pass_make_worktree_base="$(cfg_or base main)"
  "$FLOW_PLUGIN/scripts/steward.sh" claim "$1" --branch "$epic_pass_make_worktree_branch" --base "$epic_pass_make_worktree_base"
  epic_pass_make_worktree_claimed=$?
  case "$epic_pass_make_worktree_claimed" in
    0) return 0 ;;
    "$claim_pool_full" | "$claim_refused") ;;
    *) return 1 ;;
  esac
  "$FLOW_PLUGIN/scripts/steward.sh" tmp tip "$1" "$epic_pass_make_worktree_branch"
}

epic_pass_temporary() {
  case "$1" in "$(flow_home)/tmp/"*) return 0 ;; esac
  return 1
}

epic_pass_note() {
  epic_pass_note_branch="$(epic_branch "$1")"
  if epic_pass_temporary "$2"; then
    printf ' This pass works in %s, a temporary worktree detached at the tip of %s: work and commit there, push with git push origin HEAD:%s, and claim no other worktree.' \
      "$2" "$epic_pass_note_branch" "$epic_pass_note_branch"
  else
    printf ' This pass works in %s, claimed on %s: work there and claim no other worktree.' "$2" "$epic_pass_note_branch"
  fi
}

epic_pass_pushed() {
  epic_pass_pushed_branch="$(epic_branch "$1")"
  git -C "$2" fetch -q origin "+refs/heads/$epic_pass_pushed_branch:refs/remotes/origin/$epic_pass_pushed_branch" \
    && git -C "$2" merge-base --is-ancestor HEAD "refs/remotes/origin/$epic_pass_pushed_branch"
}

epic_pass_end_worktree() {
  epic_pass_pushed "$1" "$2" || { echo "flow: $2 holds commits origin/$(epic_branch "$1") lacks, or the remote cannot be read" >&2; return 1; }
  [ -z "$(git -C "$2" status --porcelain --untracked-files=normal -- . ':!.flow' 2>/dev/null)" ] || { echo "flow: $2 holds uncommitted changes" >&2; return 1; }
  if epic_pass_temporary "$2"; then "$FLOW_PLUGIN/scripts/steward.sh" tmp remove "$2" >/dev/null; return; fi
  "$FLOW_PLUGIN/scripts/steward.sh" release "$2" >/dev/null
}
