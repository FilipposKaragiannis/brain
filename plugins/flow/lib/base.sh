# The base of an item: the branch its work starts from and its PR merges into. Resolved once, when
# the item is first claimed, and recorded in claim.json and the item state (base). Sourced after
# lib/flow.sh by scripts/next.sh, scripts/verify.sh, scripts/steward.sh, scripts/board.sh,
# hooks/worktree-create.sh and skills/init/scripts/init.sh.

# The ancestors fetch_item_base reads for an epic branch, from the parent up.
base_ancestor_levels=5

# epic_branch <id>: gh#N gives epic/N, local:epic/3 epic/3, jira:PROJ-12 epic/PROJ-12.
epic_branch() { printf 'epic/%s' "${1##*[#/:]}"; }

# flow_repository: the repository the flow home belongs to, where the base branches live.
flow_repository() { dirname "$(flow_home)"; }

# base_name_valid <branch>: true for a branch name that is safe to claim from, to name in a brief
# and to pass to git. A name git would read as an option, or that carries a shell character (a base
# reaches merge instructions in the brief and the board table), never is; nor a letter outside ASCII,
# which a UTF-8 locale would let through the ranges.
base_name_valid() {
  (LC_ALL=C; case "$1" in -*|'') exit 1 ;; *[!A-Za-z0-9._/-]*) exit 1 ;; esac) || return 1
  git -C "$(flow_repository)" check-ref-format "refs/heads/$1"
}

# checked_name <branch>: the name, or nothing and 1 when it fails base_name_valid.
checked_name() { base_name_valid "$1" && printf '%s' "$1"; }

# fetch_base <branch>: fetches the branch from origin into refs/remotes/origin/<branch>, when the
# repository has an origin and the name is valid. A failed fetch (offline) leaves the remote ref as
# the last fetch saw it.
fetch_base() {
  base_name_valid "$1" || return 0
  git -C "$(flow_repository)" remote get-url origin >/dev/null 2>&1 || return 0
  git -C "$(flow_repository)" fetch -q origin "$1" >/dev/null 2>&1
}

# base_exists <branch>: true when the last fetch saw the branch on the remote; in a repository with
# no origin, when it is a local branch. No fetch: fetch_base first for a fresh answer.
base_exists() {
  base_name_valid "$1" || return 1
  if git -C "$(flow_repository)" remote get-url origin >/dev/null 2>&1; then
    git -C "$(flow_repository)" show-ref --verify --quiet "refs/remotes/origin/$1"
    return
  fi
  git -C "$(flow_repository)" show-ref --verify --quiet "refs/heads/$1"
}

# body_base <item-json>: the branch a `base: <branch>` line of the item's body names (the first
# such line, backticks stripped), or nothing.
body_base() {
  json_get "$1" body | tr -d '`\r' | sed -n 's/^base:[[:blank:]]*\([^[:blank:]][^[:blank:]]*\).*/\1/p' | head -n 1
}

# claim_name <worktree> <field>: the branch name the field (base or branch) of the worktree's
# claim.json holds, or nothing and 1 when the name fails base_name_valid. claim.json is a file
# anyone can edit, so next.sh, verify.sh, the board, init and the claim of a child check a name
# here before git, a brief or the board takes it. steward.sh's release, split and health still read
# the base field as it is.
claim_name() { checked_name "$(json_get "$(cat "$(claim_file "$1")" 2>/dev/null)" "$2")"; }

# recorded_base <worktree>: the base the worktree's claim records, else the config base: a claim
# made before the base was recorded was cut from it.
recorded_base() { claim_name "$1" base || cfg_or base main; }

# parent_branch <parent>: the branch of the parent's claim, or nothing when it holds none or its
# branch is no valid base.
parent_branch() {
  parent_worktree="$("$FLOW_PLUGIN/scripts/steward.sh" find "$1" </dev/null 2>/dev/null)"
  [ -z "$parent_worktree" ] || claim_name "$parent_worktree" branch
}

# fetch_epic_ancestor <parent>: fetches the epic branch of each epic from the parent up and prints
# the first epic whose epic branch exists; nothing, and 1, when none does within
# base_ancestor_levels, before an id comes twice, or at an id no adapter owns (it is never read).
# A task or bug ancestor is walked past, never matched: its number may also be an epic's.
fetch_epic_ancestor() {
  ancestor="$1"; ancestors_seen=" "; ancestor_level=0
  while [ -n "$ancestor" ] && [ "$ancestor_level" -lt "$base_ancestor_levels" ]; do
    case "$ancestors_seen" in *" $ancestor "*) return 1 ;; esac
    adapter_for "$ancestor" >/dev/null 2>&1 || return 1
    ancestor_json="$(adapter read "$ancestor" </dev/null 2>/dev/null)"
    if [ "$(json_get "$ancestor_json" kind)" = epic ]; then
      ancestor_branch="$(epic_branch "$ancestor")"
      fetch_base "$ancestor_branch"
      if base_exists "$ancestor_branch"; then printf '%s' "$ancestor"; return 0; fi
    fi
    ancestors_seen="$ancestors_seen$ancestor "; ancestor_level=$((ancestor_level + 1))
    ancestor="$(json_get "$ancestor_json" parent)"
  done
  return 1
}

# fetch_item_base <item-json>: `<branch>\t<why>`, the base a new claim of the item starts from,
# fetching each epic and `base:` branch it tries. In order: the branch of the parent's claim; the
# epic branch of the nearest ancestor that has one on the remote; the branch of a `base:` line in
# the item's body; the config base. A `base:` line naming a branch that does not exist prints that
# branch and returns 1: a claim from the config base would put the work on the wrong history.
fetch_item_base() {
  item_parent="$(json_get "$1" parent)"
  if [ -n "$item_parent" ]; then
    claimed_parent_branch="$(parent_branch "$item_parent")"
    if [ -n "$claimed_parent_branch" ]; then printf '%s\ttask branch of %s' "$claimed_parent_branch" "$item_parent"; return 0; fi
    if epic_owner="$(fetch_epic_ancestor "$item_parent")"; then printf '%s\tepic branch of %s' "$(epic_branch "$epic_owner")" "$epic_owner"; return 0; fi
  fi
  named_base="$(body_base "$1")"
  if [ -n "$named_base" ]; then
    printf '%s\tbase: line in the item' "$named_base"
    fetch_base "$named_base"
    base_exists "$named_base"
    return
  fi
  printf '%s\tconfig base' "$(cfg_or base main)"
}

# Why a claim refuses a base: line whose name fails base_name_valid. The name stays out: it may
# carry control characters.
base_name_refused='its base is not a valid branch name'

# claim_base_option <default> [--base <branch>]: the base steward.sh claim cuts the worktree from and
# records in claim.json and the item state (base): the branch --base names (next.sh passes the one
# claim_at_base resolved), else the default, the config base. An unknown option, --base with no
# branch, or a base that fails base_name_valid, dies with exit 2. An item that holds a claim keeps
# it and its base, whatever --base says.
claim_base_option() {
  option_base="$1"; shift
  while [ $# -gt 0 ]; do case "$1" in --base) [ $# -ge 2 ] || die "--base takes a branch" 2; option_base="$2"; shift 2 ;; *) die "unknown option $1" 2 ;; esac; done
  base_name_valid "$option_base" || die "the base is not a valid branch name" 2
  printf '%s' "$option_base"
}

# claim_at_base <item> <item-json>: claims a pool worktree for the item and prints its path. A new
# claim starts from the base fetch_item_base resolves, and the events log says which and why; an
# item that holds a claim keeps it and its base, and nothing is fetched. A base: line naming a
# branch not on the remote, or no valid name, writes why to the item's last_event and stderr and
# returns 4: a claim from the config base would put the work on the wrong history. Else the exit
# code of steward.sh claim (3: no free worktree).
claim_at_base() {
  claimed_worktree="$("$FLOW_PLUGIN/scripts/steward.sh" find "$1")"
  if [ -n "$claimed_worktree" ]; then printf '%s\n' "$claimed_worktree"; return 0; fi
  resolved_base="$(fetch_item_base "$2")"; resolved_code=$?
  claim_base="$(printf '%s\n' "$resolved_base" | cut -f1)"; claim_why="$(printf '%s\n' "$resolved_base" | cut -f2-)"
  if [ "$resolved_code" -ne 0 ]; then
    claim_refusal="$base_name_refused"
    base_name_valid "$claim_base" && claim_refusal="its base $claim_base is not on the remote"
    adapter write-state "$1" "last_event=$(now_iso) $claim_refusal" >/dev/null
    echo "$1: $claim_refusal" >&2; return 4
  fi
  claimed_worktree="$("$FLOW_PLUGIN/scripts/steward.sh" claim "$1" --base "$claim_base")" || return
  printf '%s\t%s\tclaim\tbase %s (%s)\n' "$(now_iso)" "$1" "$claim_base" "$claim_why" >> "$(flow_home)/events.log"
  printf '%s\n' "$claimed_worktree"
}

# base_missing <branch>: true when the repository has an origin and refs/remotes/origin/<branch> is
# absent. No fetch: the board and init read what the last fetch saw, so they stay fast and work
# offline. With no origin nothing is missing.
base_missing() {
  git -C "$(flow_repository)" remote get-url origin >/dev/null 2>&1 || return 1
  ! git -C "$(flow_repository)" show-ref --verify --quiet "refs/remotes/origin/$1"
}

# claimed_bases: `<item>\t<base>\t<worktree path>\t<missing>` for each claimed pool worktree whose
# claim records a valid base; missing is true or false, as base_missing says. A claim whose item
# carries a control character is left out too: a tab or a line break would split the record.
claimed_bases() {
  cfg pool | while read -r pool_entry; do
    [ -n "$pool_entry" ] || continue
    case "$pool_entry" in /*) pool_worktree="$pool_entry" ;; *) pool_worktree="$(flow_repository)/$pool_entry" ;; esac
    [ -f "$(claim_file "$pool_worktree")" ] || continue
    claimed_item="$(json_get "$(cat "$(claim_file "$pool_worktree")")" item)"; claimed_base="$(claim_name "$pool_worktree" base)"
    [ -n "$claimed_item" ] && [ -n "$claimed_base" ] || continue
    case "$claimed_item" in *[![:print:]]*) continue ;; esac
    if base_missing "$claimed_base"; then claimed_base_missing=true; else claimed_base_missing=false; fi
    printf '%s\t%s\t%s\t%s\n' "$claimed_item" "$claimed_base" "$(cd "$pool_worktree" && pwd)" "$claimed_base_missing"
  done
}

# missing_base_notes: a line for each claim whose base is not on the remote (deleted after the
# claim, or never pushed), naming the item, its worktree and the base: the work has no branch to
# merge into. The same test as the board (claimed_bases), no fetch.
missing_base_notes() {
  claimed_bases | while IFS="$(printf '\t')" read -r claimed_item claimed_base claimed_worktree claimed_base_missing; do
    [ "$claimed_base_missing" = true ] || continue
    printf '%s in %s: base %s is not on the remote\n' "$claimed_item" "$claimed_worktree" "$claimed_base"
  done
}
