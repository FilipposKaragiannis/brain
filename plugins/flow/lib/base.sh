# The base of an item: the branch its work starts from and its PR merges into. Resolved once, when
# the item is first claimed, and recorded in claim.json and the item state (base). Sourced after
# lib/flow.sh by scripts/next.sh, scripts/board.sh and skills/init/scripts/init.sh.

# The ancestors resolve_base reads for an epic branch, from the parent up.
base_ancestor_levels=5

# epic_branch <id>: epic/<n>, <n> the id with everything up to its last #, / or : removed
# (gh#525 gives epic/525, local:epic/3 epic/3, jira:PROJ-12 epic/PROJ-12).
epic_branch() { printf 'epic/%s' "${1##*[#/:]}"; }

# base_exists <branch>: true when the branch is on the remote, after a fetch of it; in a repository
# with no origin, when it is a local branch. A failed fetch (offline) leaves the remote ref as the
# last fetch saw it. A name git would read as an option, or that is no branch name, never exists.
base_exists() {
  case "$1" in -*|'') return 1 ;; esac
  base_repository="$(dirname "$(flow_home)")"
  git -C "$base_repository" check-ref-format "refs/heads/$1" || return 1
  if git -C "$base_repository" remote get-url origin >/dev/null 2>&1; then
    git -C "$base_repository" fetch -q origin "$1" >/dev/null 2>&1
    git -C "$base_repository" show-ref --verify --quiet "refs/remotes/origin/$1"
    return
  fi
  git -C "$base_repository" show-ref --verify --quiet "refs/heads/$1"
}

# body_base <item-json>: the branch a `base: <branch>` line of the item's body names (the first
# such line, backticks stripped), or nothing.
body_base() {
  json_get "$1" body | tr -d '`\r' | sed -n 's/^base:[[:blank:]]*\([^[:blank:]][^[:blank:]]*\).*/\1/p' | head -n 1
}

# parent_branch <parent>: the branch of the parent's claim, or nothing when it holds none.
parent_branch() {
  parent_worktree="$("$FLOW_PLUGIN/scripts/steward.sh" find "$1" </dev/null 2>/dev/null)"
  [ -z "$parent_worktree" ] || json_get "$(cat "$(claim_file "$parent_worktree")" 2>/dev/null)" branch
}

# epic_ancestor <parent>: the first id from the parent up whose epic branch exists; nothing, and 1,
# when none does within base_ancestor_levels or before an id comes twice.
epic_ancestor() {
  ancestor="$1"; ancestors_seen=" "; ancestor_level=0
  while [ -n "$ancestor" ] && [ "$ancestor_level" -lt "$base_ancestor_levels" ]; do
    case "$ancestors_seen" in *" $ancestor "*) return 1 ;; esac
    if base_exists "$(epic_branch "$ancestor")"; then printf '%s' "$ancestor"; return 0; fi
    ancestors_seen="$ancestors_seen$ancestor "; ancestor_level=$((ancestor_level + 1))
    ancestor="$(json_get "$(adapter read "$ancestor" </dev/null 2>/dev/null)" parent)"
  done
  return 1
}

# resolve_base <item-json>: `<branch>\t<why>`, the base a new claim of the item starts from. In
# order: the branch of the parent's claim; the epic branch of the nearest ancestor that has one on
# the remote; the branch of a `base:` line in the item's body; the config base. A `base:` line
# naming a branch that does not exist prints that branch and returns 1: a claim from the config base
# would put the work on the wrong history.
resolve_base() {
  item_parent="$(json_get "$1" parent)"
  if [ -n "$item_parent" ]; then
    claimed_parent_branch="$(parent_branch "$item_parent")"
    if [ -n "$claimed_parent_branch" ]; then printf '%s\ttask branch of %s' "$claimed_parent_branch" "$item_parent"; return 0; fi
    if epic_owner="$(epic_ancestor "$item_parent")"; then printf '%s\tepic branch of %s' "$(epic_branch "$epic_owner")" "$epic_owner"; return 0; fi
  fi
  named_base="$(body_base "$1")"
  if [ -n "$named_base" ]; then
    printf '%s\tbase: line in the item' "$named_base"
    base_exists "$named_base"
    return
  fi
  printf '%s\tconfig base' "$(cfg_or base main)"
}

# base_missing <branch>: true when the repository has an origin and refs/remotes/origin/<branch> is
# absent. No fetch: the board and init read what the last fetch saw, so they stay fast and work
# offline. With no origin nothing is missing.
base_missing() {
  base_repository="$(dirname "$(flow_home)")"
  git -C "$base_repository" remote get-url origin >/dev/null 2>&1 || return 1
  ! git -C "$base_repository" show-ref --verify --quiet "refs/remotes/origin/$1"
}

# claimed_bases: one line per claimed pool worktree whose claim records a base,
# `<item>\t<base>\t<worktree path>\t<missing>`, missing true when base_missing says so, else false.
# Read by board.sh and init.sh, which name a base that is not on the remote.
claimed_bases() {
  base_repository="$(dirname "$(flow_home)")"
  cfg pool | while read -r pool_entry; do
    [ -n "$pool_entry" ] || continue
    case "$pool_entry" in /*) pool_worktree="$pool_entry" ;; *) pool_worktree="$base_repository/$pool_entry" ;; esac
    [ -f "$(claim_file "$pool_worktree")" ] || continue
    pool_claim="$(cat "$(claim_file "$pool_worktree")")"
    claimed_item="$(json_get "$pool_claim" item)"; claimed_base="$(json_get "$pool_claim" base)"
    [ -n "$claimed_item" ] && [ -n "$claimed_base" ] || continue
    if base_missing "$claimed_base"; then claimed_base_missing=true; else claimed_base_missing=false; fi
    printf '%s\t%s\t%s\t%s\n' "$claimed_item" "$claimed_base" "$(cd "$pool_worktree" && pwd)" "$claimed_base_missing"
  done
}
