# epic_closeout_claim.sh: the pool worktree an epic's closeout runs in, claimed by scripts/next.sh
# and released by scripts/advance.sh. Sourced after lib/flow.sh and lib/base.sh by both.
#
# claim_epic_branch <epic> <epic-json> claims it on the epic branch at the tip the remote holds
# (steward.sh claim-tip), with the epic's start (fetch_epic_start) as its base, and prints its
# path. It prints nothing when the repository has no origin or the remote answers that it has no
# epic branch: the closeout runs in the main checkout. A remote that cannot be asked, or a start
# that does not resolve, writes why to the epic's last_event and stderr and returns $claim_refused:
# not seeing the branch is no proof it holds nothing. Else the exit code of steward.sh claim-tip.
#
# release_epic_closeout_claim <plugin> <step> <kind> <item> releases the claim steward.sh find
# names for an epic's closeout, whatever its outcome, never the run's worktree: that is the main
# checkout when the epic has no epic branch. A release that fails says so on stderr and leaves the
# outcome as it is.

# The exit code of git ls-remote --exit-code when the remote holds no matching ref.
ls_remote_no_match=2

# shellcheck disable=SC2154 # lib/base.sh, sourced first, sets claim_refused
claim_epic_branch() {
  git -C "$(flow_repository)" remote get-url origin >/dev/null 2>&1 || return 0
  claim_epic_branch_name="$(epic_branch "$1")"
  git -C "$(flow_repository)" ls-remote --exit-code --heads origin "$claim_epic_branch_name" >/dev/null 2>&1; claim_epic_branch_asked=$?
  [ "$claim_epic_branch_asked" -ne "$ls_remote_no_match" ] || return 0
  if [ "$claim_epic_branch_asked" -ne 0 ]; then
    record_epic_claim_refusal "$1" "the remote could not be asked for $claim_epic_branch_name, so its closeout has no branch to check"; return "$claim_refused"
  fi
  claim_epic_branch_start="$(fetch_epic_start "$2")" || { record_epic_claim_refusal "$1" "$claim_epic_branch_start"; return "$claim_refused"; }
  claim_epic_branch_worktree="$("$FLOW_PLUGIN/scripts/steward.sh" claim-tip "$1" "$claim_epic_branch_name" --base "$claim_epic_branch_start")" || return
  printf '%s\t%s\tclaim\t%s at its remote tip, base %s (the epic start)\n' "$(now_iso)" "$1" "$claim_epic_branch_name" "$claim_epic_branch_start" >> "$(flow_home)/events.log"
  printf '%s\n' "$claim_epic_branch_worktree"
}

record_epic_claim_refusal() {
  adapter write-state "$1" "last_event=$(now_iso) $2" >/dev/null
  echo "$1: $2" >&2
}

release_epic_closeout_claim() {
  [ "$2" = closeout ] && [ "$3" = epic ] || return 0
  release_epic_closeout_claim_worktree="$("$1/scripts/steward.sh" find "$4")"
  [ -n "$release_epic_closeout_claim_worktree" ] || return 0
  "$1/scripts/steward.sh" release "$release_epic_closeout_claim_worktree" >/dev/null \
    || echo "advance: could not release $release_epic_closeout_claim_worktree after the closeout of $4" >&2
}
