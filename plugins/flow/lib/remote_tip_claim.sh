# remote_tip_claim.sh: steward.sh claim-tip, a pool worktree on a branch that exists on the remote,
# at the tip the remote holds. An epic's closeout runs there: its pull request merges that tip,
# and the branch is the epic branch, which no task branch template names (claim_branch). The
# branch is fetched fresh, through its own refspec, so a clone that tracks only some branches
# still sees the remote's tip. A local copy of the branch behind the remote moves up to the tip;
# one that holds commits the remote lacks, or that another worktree has checked out, is refused
# with why, exit 4, before any worktree is taken. An item that holds a claim on the branch keeps
# its worktree, moved up to the tip the same way; one on another branch is refused. worktree_setup runs again after the move as for any claim (worktree_setup_paths).
# Sourced by scripts/steward.sh, never run.
# shellcheck disable=SC2154 # scripts/steward.sh, which sources it, sets main and base_branch, and lib/base.sh the claim exit codes

tip_claim_fetch_tracking_branch() {
  tip_claim_fetch_tracking_branch_name="refs/remotes/origin/$2"
  git -C "$main" fetch -q origin "+refs/heads/$2:$tip_claim_fetch_tracking_branch_name" >/dev/null 2>&1 \
    || refuse_claim "$1" "$2 could not be fetched, so the tip the remote holds is not known" "$claim_refused"
  printf '%s' "$tip_claim_fetch_tracking_branch_name"
}

tip_claim_holder() {
  tip_claim_holder_folder="$(git -C "$main" worktree list --porcelain | awk -v wanted="branch refs/heads/$1" '
    /^worktree / { folder = $0; sub(/^worktree /, "", folder) }
    $0 == wanted { print folder; exit }')"
  [ -n "$tip_claim_holder_folder" ] || return 0
  (cd "$tip_claim_holder_folder" 2>/dev/null && pwd -P) || printf '%s\n' "$tip_claim_holder_folder"
}

tip_claim_refuse_unusable_local_branch() {
  git -C "$main" show-ref --verify --quiet "refs/heads/$2" || return 0
  tip_claim_refuse_unusable_local_branch_holder="$(tip_claim_holder "$2")"
  if [ -n "$tip_claim_refuse_unusable_local_branch_holder" ] && [ "$tip_claim_refuse_unusable_local_branch_holder" != "$4" ]; then
    refuse_claim "$1" "$2 is checked out in $tip_claim_refuse_unusable_local_branch_holder, so no pool worktree can take it" "$claim_refused"
  fi
  git -C "$main" merge-base --is-ancestor "refs/heads/$2" "$3" \
    || refuse_claim "$1" "the local $2 holds commits origin/$2 lacks: push them or drop them, then run the step again" "$claim_refused"
}

tip_claim_refuse_branch_name() {
  branch_name_valid "$2" || refuse_claim "$1" "$branch_name_refused" "$claim_call_refused"
  ! branch_is_base "$2" "$3" || refuse_claim "$1" "$branch_base_refused" "$claim_call_refused"
}

tip_claim_move_existing_to_tip() {
  [ "$(json_get "$(claim_of "$2")" branch)" = "$3" ] || refuse_claim "$1" "its claim of $(basename "$2") holds another branch than $3" "$claim_refused"
  wait_for_running_setup "$2"
  tip_claim_refuse_unusable_local_branch "$1" "$3" "$4" "$(cd "$2" && pwd -P)"
  git -C "$2" merge -q --ff-only "$4" >/dev/null 2>&1 || die "cannot move $3 in $2 up to $4"
  set_up_again_when_outdated "$2" >&2
  printf '%s\n' "$2"
}

tip_claim_new() {
  ! claimed_branch "$2" || refuse_claim "$1" "another claim holds $2" "$claim_refused"
  tip_claim_refuse_unusable_local_branch "$1" "$2" "$3" ""
  claim_lock
  ! claimed_branch "$2" || refuse_claim "$1" "another claim holds $2" "$claim_refused"
  tip_claim_new_worktree="$(free_worktree)" || exit $?
  git -C "$tip_claim_new_worktree" switch -q -C "$2" "$3" || die "cannot switch $tip_claim_new_worktree to $2 at $3"
  record_claim_unlock_and_set_up "$tip_claim_new_worktree" "$1" "$2" "$4" "claimed $(basename "$tip_claim_new_worktree") on $2 at its remote tip"
}

cmd_claim_tip() {
  cmd_claim_tip_item="$1"; cmd_claim_tip_branch="$2"; shift 2
  cmd_claim_tip_base="$(claim_base_option "$base_branch" "$@")" || exit $?
  scope_holds "$cmd_claim_tip_item" || exit "$claim_call_refused"
  tip_claim_refuse_branch_name "$cmd_claim_tip_item" "$cmd_claim_tip_branch" "$cmd_claim_tip_base"
  cmd_claim_tip_tracking_branch="$(tip_claim_fetch_tracking_branch "$cmd_claim_tip_item" "$cmd_claim_tip_branch")" || exit $?
  cmd_claim_tip_existing="$(cmd_find "$cmd_claim_tip_item")"
  if [ -n "$cmd_claim_tip_existing" ]; then
    tip_claim_move_existing_to_tip "$cmd_claim_tip_item" "$cmd_claim_tip_existing" "$cmd_claim_tip_branch" "$cmd_claim_tip_tracking_branch"; return
  fi
  tip_claim_new "$cmd_claim_tip_item" "$cmd_claim_tip_branch" "$cmd_claim_tip_tracking_branch" "$cmd_claim_tip_base"
}
