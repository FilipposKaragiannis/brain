#!/bin/sh
# Worktree steward: the pool, claims, releases and temporary worktrees.
#   steward.sh pool                              list the pool with claim, branch and dirt
#   steward.sh claim <item> [--base <branch>]    claim a free pool worktree, print its path
#   steward.sh find <item>                       print the claimed path, or nothing
#   steward.sh reserve [<worktree>] [--name <who>]
#                                                claim a free pool worktree for manual work, with
#                                                no item, under <who> (default: git user.name, else
#                                                $USER); print its path. <worktree> (a pool path or
#                                                name) takes that one, and exits 3 with the reason
#                                                when it is claimed, reserved, dirty or not in the
#                                                pool. claim, sweep, health and next leave it alone
#                                                until release frees it
#   steward.sh release <item|path> [--force]     back to its idle branch (<base>-wt-<n>) at the base
#                                                tip, delete the task branch, clear the claim; a
#                                                closed item's reports go too
#   steward.sh reports <item>                    print (and create) the item's reports folder
#   steward.sh tmp add <item> <phase>            temporary worktree from the task branch
#   steward.sh tmp remove <path>                 remove it and its branch
#   steward.sh add [path]                        add a worktree to the pool (git worktree add,
#                                                pool entry in config.yaml, copies and setup); a
#                                                pool path missing on disk is recreated in place
#   steward.sh setup <path>                      run worktree_copy and worktree_setup there
#   steward.sh prune [--dry-run]                 delete the reports of closed items, in the main
#                                                worktree and every pool worktree
#   steward.sh sweep [--dry-run] [--lock] [--item <id>]
#                                                release each worktree whose work landed: its item
#                                                is closed, or its PR is merged. --item looks at
#                                                that item's worktree only. --lock takes the sweep
#                                                lock first and exits 75 when it is held
#   steward.sh split <item>                      a task split into tracker tasks waits on its
#                                                children: step split, its worktree released
#                                                (kept when dirty), its branch kept when it holds
#                                                commits past the base
#   steward.sh keep-whole <item>                 the owner kept it whole: no split until its plan
#                                                step rewrites plan.md (kept-whole <item> asks)
#   steward.sh health [--dry-run] [--host H] [--wait] [--model M] [--effort E]
#                                                check every claim: clear a dead run, release an
#                                                empty claim, finish a split, resume cut-off work,
#                                                sync branches, remind on old gates, clear stale
#                                                or wrong holds and name old ones, say when the
#                                                pool is stuck, discard a free worktree's changes
#                                                the base's history already holds
#   steward.sh sessions [--stale]                list the claude and codex sessions working in the
#                                                main worktree and the pool: pid, host, worktree,
#                                                item, busy or idle and for how long; a stale one
#                                                (idle past jobs.health.stale_session, 24h) ends in
#                                                the kill command. --stale lists only those
#   steward.sh stop <item>                       end the item's run: its process and every one under
#                                                it; the record goes, so health does not resume it;
#                                                the claim, the worktree and its changes stay
#   steward.sh resume <item> [--host H] [--wait] [--model M] [--effort E]
#                                                start a run whose process is gone again where it
#                                                stopped, as health resumes one; a live run or no
#                                                record is refused, exit 1. --model and --effort
#                                                replace jobs.<host>.model and .effort for the
#                                                resumed run's steps with no agent, in both
# A claim with no free worktree adds one while the pool is below pool_max (config.yaml), named by
# the worktree_name template (../{repo}-wt-{n}: {repo} the main worktree's folder, {n} the first
# number no pool entry and no folder uses); unset, after the last pool entry (../app-wt-3 after
# ../app-wt-2). A template with no {n}, or one that gives every number the same idle branch, is
# refused with its reason, exit 2. worktree_copy lists ignored paths copied from the main
# worktree when the new one lacks them (.claude/settings.local.json); worktree_setup lists
# commands run in the new worktree. Both run on add and on setup.
# A listed pool path missing on disk (Claude Code, or a hand, removed the folder after a release)
# counts as free: claim and reserve recreate it on its idle branch at the base tip, with the
# copies and the setup, and health names it with the command that recreates it now.
# Never resets a worktree with uncommitted changes: release exits 3 and says so (escalate). The one
# exception is health's, for a free worktree whose changes the base's history already holds.
. "$(dirname "$0")/../lib/flow.sh"

home="$(flow_home)"
main="$(dirname "$home")"
base_branch="$(cfg_or base main)"

# pool_paths: the pool entries as absolute paths. One missing on disk is spelt from its parent
# folder, so it carries no .. and names the folder a recreate makes (Claude Code refuses a
# worktree path with .. in it).
pool_paths() {
  cfg pool | while read -r p; do
    [ -n "$p" ] || continue
    case "$p" in /*) if [ -d "$p" ]; then printf '%s\n' "$p"; else printf '%s\n' "$(pool_spelling "$p")"; fi ;; *) printf '%s\n' "$(cd "$main" && cd "$p" 2>/dev/null && pwd || pool_spelling "$main/$p")" ;; esac
  done
}
# pool_spelling <path>: the path with its parent folder resolved, as is when the parent is gone too.
pool_spelling() {
  ps_parent="$(cd "$(dirname "$1")" 2>/dev/null && pwd)" && printf '%s/%s' "$ps_parent" "$(basename "$1")" || printf '%s' "$1"
}

base_ref() {
  b="${1:-$base_branch}"
  if git -C "$main" show-ref --verify --quiet "refs/remotes/origin/$b"; then printf 'origin/%s' "$b"; else printf '%s' "$b"; fi
}

claim_of() { [ -f "$1/.flow/claim.json" ] && cat "$1/.flow/claim.json"; }
# reserved_by <path>: who reserved the worktree for manual work (reserve), or nothing.
reserved_by() { json_get "$(claim_of "$1")" reserved; }

# idle_branch <path>: the branch a free pool worktree sits on, one per worktree, because git checks
# a branch out in one worktree at a time: <base>-wt-<n> for ../app-wt-<n>, else <base>-<folder>.
idle_branch() {
  ib_name="$(basename "$1")"
  case "$ib_name" in *-wt-*) printf '%s-wt-%s' "$base_branch" "${ib_name##*-wt-}" ;; *) printf '%s-%s' "$base_branch" "$ib_name" ;; esac
}
# idle_kept <branch>: true when the idle branch exists with commits the base tip lacks, so moving
# it to the tip would drop them.
idle_kept() {
  git -C "$main" show-ref --verify --quiet "refs/heads/$1" && ! git -C "$main" merge-base --is-ancestor "refs/heads/$1" "$(base_ref)" 2>/dev/null
}
# park <path>: put a free worktree on its idle branch at the base tip. An idle branch with commits
# of its own is kept: the worktree goes detached at the tip instead, and park returns 1. Returns 2
# when git cannot move it.
park() {
  pk_branch="$(idle_branch "$1")"
  if idle_kept "$pk_branch"; then git -C "$1" switch -q --detach "$(base_ref)" || return 2; return 1; fi
  git -C "$1" switch -q --no-track -C "$pk_branch" "$(base_ref)" || return 2
}

# .flow/ holds the claim and the reports and is never part of the work.
dirty() { [ -n "$(git -C "$1" status --porcelain -- . ":!.flow" 2>/dev/null)" ]; }

write_state() {
  # write_state <item> key=value... ; skipped for ids no adapter owns (ad hoc worktree sessions).
  adapter_for "$1" >/dev/null 2>&1 || return 0
  item="$1"; shift
  adapter write-state "$item" "$@" >/dev/null || echo "flow: could not write state for $item" >&2
}

cmd_pool() {
  printf '%-28s %-32s %-22s %-10s %s\n' worktree branch item step state
  pool_paths | while read -r p; do
    [ -d "$p" ] || { printf '%-28s %s\n' "$(basename "$p")" "MISSING ($p)"; continue; }
    branch="$(git -C "$p" symbolic-ref --short -q HEAD || git -C "$p" rev-parse --short HEAD 2>/dev/null)"
    c="$(claim_of "$p")"
    item="$(json_get "$c" item)"; step="$(json_get "$c" step)"
    st="free"; [ -n "$item" ] && st="claimed"
    rv="$(json_get "$c" reserved)"; [ -z "$rv" ] || st="reserved by $rv"
    dirty "$p" && st="$st, uncommitted changes"
    printf '%-28s %-32s %-22s %-10s %s\n' "$(basename "$p")" "${branch:-?}" "${item:--}" "${step:--}" "$st"
  done
}

cmd_find() {
  pool_paths | while read -r p; do
    [ "$(json_get "$(claim_of "$p")" item)" = "$1" ] && { printf '%s\n' "$p"; exit 0; }
  done
}

cmd_claim() {
  item="$1"; shift
  base="$base_branch"
  while [ $# -gt 0 ]; do case "$1" in --base) base="$2"; shift 2 ;; *) die "unknown option $1" 2 ;; esac; done
  existing="$(cmd_find "$item")"
  if [ -n "$existing" ]; then printf '%s\n' "$existing"; return 0; fi
  slug="$(item_slug "$item")"; branch="flow/$slug"
  git -C "$main" remote get-url origin >/dev/null 2>&1 && git -C "$main" fetch -q origin "$base" 2>/dev/null
  ref="$(base_ref "$base")"
  claim_lock
  existing="$(cmd_find "$item")"
  if [ -n "$existing" ]; then flow_unlock; printf '%s\n' "$existing"; return 0; fi
  free="$(free_worktree)" || exit $?
  if git -C "$free" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$free" switch -q "$branch" || die "cannot switch $free to $branch"
  else
    git -C "$free" switch -q -c "$branch" "$ref" || die "cannot create $branch from $ref in $free"
  fi
  mkdir -p "$free/.flow"
  json_obj "item=$item" "worktree=$free" "name=$(basename "$free")" "branch=$branch" "base=$base" "step=" \
    "claimed_at=$(now_iso)" "host=$(host_name)" > "$free/.flow/claim.json"
  flow_unlock
  write_state "$item" "worktree=$(basename "$free")" "last_event=$(now_iso) claimed $(basename "$free")"
  printf '%s\n' "$free"
}

# free_worktree: the first pool worktree with no claim, no reservation and a clean tree, or a
# pool path missing on disk, recreated and printed resolved (one git cannot add is skipped,
# saying why); else one grow_pool adds; exit 3 when the pool is at pool_max. A refused worktree_name exits 2 inside
# grow_pool, before the pool_max message, so claim and reserve pass the template's reason through.
free_worktree() {
  for p in $(pool_paths); do
    if [ ! -d "$p" ]; then
      pool_recreate "$p" >&2 || continue
      # A path whose parent was missing too is still spelt with .. here; resolve it now it exists.
      (cd "$p" && pwd); return 0
    fi
    [ -z "$(json_get "$(claim_of "$p")" item)" ] && [ -z "$(reserved_by "$p")" ] || continue
    dirty "$p" && continue
    printf '%s\n' "$p"; return 0
  done
  grow_pool || die "no free worktree in the pool (every pool entry is claimed, reserved, dirty or missing) and the pool is at pool_max ($(cfg_or pool_max 0)). Release one, or raise pool_max in $(config_file)." 3
}

# claim_lock: one worktree allocation at a time. claim (from next, the worktree hook or by hand)
# and reserve take it, so two of them never write the same claim.json. Not the pick lock: next
# holds that while it runs claim. Exits 75 when another allocation holds it past the lock wait.
claim_lock() {
  flow_lock claim || die "the claim lock is busy (another claim or reserve is taking a worktree); try again" 75
}

# named_worktree <path or name>: the pool worktree a path or a folder name names, when it is free:
# no claim, no reservation and a clean tree. Else exit 3 with the reason, so reserve never takes a
# worktree the flow or someone else holds.
named_worktree() {
  nw_want="$1"; nw_abs=""
  case "$nw_want" in */*) nw_abs="$(cd "$nw_want" 2>/dev/null && pwd -P)" ;; esac
  for p in $(pool_paths); do
    if [ -n "$nw_abs" ]; then
      [ "$p" = "$nw_want" ] || [ "$(cd "$p" 2>/dev/null && pwd -P)" = "$nw_abs" ] || continue
    else
      [ "$(basename "$p")" = "$nw_want" ] || continue
    fi
    nw_name="$(basename "$p")"
    [ -d "$p" ] || die "$nw_name is in the pool but its folder is missing ($p)" 3
    nw_item="$(json_get "$(claim_of "$p")" item)"
    [ -z "$nw_item" ] || die "$nw_name is claimed by $nw_item" 3
    nw_who="$(reserved_by "$p")"
    [ -z "$nw_who" ] || die "$nw_name is reserved by $nw_who" 3
    dirty "$p" && die "$nw_name has uncommitted changes" 3
    printf '%s\n' "$p"; return 0
  done
  die "$nw_want is not a worktree in the pool ($(config_file))" 3
}

# cmd_reserve: the owner's own claim, with no item, under the claim lock: the named worktree, else
# the first free one.
cmd_reserve() {
  who=""; want=""
  while [ $# -gt 0 ]; do case "$1" in
    --name) [ $# -ge 2 ] && [ -n "$2" ] || die "--name needs a name" 2; who="$2"; shift 2 ;;
    -*) die "unknown option $1" 2 ;;
    *) [ -z "$want" ] || die "reserve takes one worktree, got $want and $1" 2; [ -n "$1" ] || die "the worktree to reserve is empty" 2; want="$1"; shift ;;
  esac; done
  [ -n "$who" ] || who="$(git -C "$main" config user.name 2>/dev/null)"
  [ -n "$who" ] || who="${USER:-}"
  [ -n "$who" ] || die "no name to reserve under: pass --name <who>" 2
  claim_lock
  if [ -n "$want" ]; then free="$(named_worktree "$want")" || exit $?
  else free="$(free_worktree)" || exit $?; fi
  mkdir -p "$free/.flow"
  json_obj "item=" "reserved=$who" "worktree=$free" "name=$(basename "$free")" "claimed_at=$(now_iso)" "host=$(host_name)" > "$free/.flow/claim.json"
  flow_unlock
  printf '%s\n' "$free"
}

resolve_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *) p="$(cmd_find "$1")"; [ -n "$p" ] && printf '%s' "$p" || { [ -d "$1" ] && (cd "$1" && pwd); } ;;
  esac
}

cmd_release() {
  target="$1"; shift
  force=0
  while [ $# -gt 0 ]; do case "$1" in --force) force=1; shift ;; *) die "unknown option $1" 2 ;; esac; done
  p="$(resolve_path "$target")"
  [ -n "$p" ] && [ -d "$p" ] || die "no claimed worktree for $target" 2
  c="$(claim_of "$p")"
  item="$(json_get "$c" item)"; branch="$(json_get "$c" branch)"; base="$(json_get "$c" base)"
  [ -n "$base" ] || base="$base_branch"
  if dirty "$p"; then
    die "$p has uncommitted changes. Not resetting. Commit or stash them, then release again (escalation)." 3
  fi
  park "$p"; parked=$?
  [ "$parked" -ne 2 ] || die "cannot move $p to $(idle_branch "$p") at $(base_ref)"
  [ "$parked" -eq 0 ] || echo "flow: $(idle_branch "$p") has commits not in $(base_ref); kept, and $(basename "$p") left detached at $(base_ref)" >&2
  # The branch goes only when the claim's base holds every commit of it: git branch -d would judge
  # it against the idle branch's tip, or delete one merged into its upstream but ahead of the base.
  if [ -n "$branch" ] && git -C "$p" show-ref --verify --quiet "refs/heads/$branch"; then
    if [ "$force" -eq 1 ]; then git -C "$p" branch -q -D "$branch"
    elif ! git -C "$p" merge-base --is-ancestor "refs/heads/$branch" "$(base_ref "$base")" 2>/dev/null ||
         ! git -C "$p" branch -q -D "$branch" 2>/dev/null; then echo "flow: $branch is not merged into $(base_ref "$base"); kept. Use --force to delete it." >&2; fi
  fi
  rm -f "$p/.flow/claim.json"
  [ -n "$item" ] && write_state "$item" "worktree=" "last_event=$(now_iso) released $(basename "$p")"
  echo "released $p"
  if [ -n "$item" ] && [ "$(item_status "$item")" = closed ]; then
    for root in "$main" $(pool_paths); do
      d="$root/.flow/reports/$(item_slug "$item")"
      [ -d "$d" ] && rm -rf "$d" && echo "removed $d ($item is closed)"
    done
  fi
  return 0
}

# plan_file <item>: the item's plan.md: in the claimed worktree's reports, else where a released
# item left them. Nothing when there is none.
plan_file() {
  pf_slug="$(item_slug "$1")"; pf_wt="$(cmd_find "$1")"
  for pf_root in $pf_wt $(pool_paths) "$main"; do
    [ -f "$pf_root/.flow/reports/$pf_slug/plan.md" ] && { printf '%s' "$pf_root/.flow/reports/$pf_slug/plan.md"; return 0; }
  done
  return 1
}
# plan_tracker_tasks <item>: the item's plan.md says its decomposition is tracker tasks.
plan_tracker_tasks() {
  ptt_plan="$(plan_file "$1")" || return 1
  grep -qiE '^Decomposition:[[:space:]]*tracker tasks' "$ptt_plan"
}
# The owner kept an item whole (closed its children, cleared the decomposition gate). The mark,
# <flow home>/kept-whole/<slug>, holds the hash of the plan.md that was set aside: until the plan
# step rewrites plan.md, no split happens, whatever children turn up. cmd_keep_whole <item>
# records it; kept_whole <item> is true while it holds and drops a mark the plan outgrew.
kept_mark() { printf '%s/kept-whole/%s' "$home" "$(item_slug "$1")"; }
cmd_keep_whole() {
  kw_plan="$(plan_file "$1")" || kw_plan=""
  mkdir -p "$home/kept-whole"
  if [ -n "$kw_plan" ]; then hash_file "$kw_plan"; else echo none; fi > "$(kept_mark "$1")"
  echo "$1 is kept whole until its plan step rewrites plan.md"
}
kept_whole() {
  [ -f "$(kept_mark "$1")" ] || return 1
  kw_plan="$(plan_file "$1")" && kw_now="$(hash_file "$kw_plan")" || kw_now=none
  [ "$kw_now" = "$(cat "$(kept_mark "$1")")" ] && return 0
  rm -f "$(kept_mark "$1")"; return 1
}

# cmd_split <item>: a task whose plan made tracker tasks of it, with children open, waits on them.
# advance.sh calls it when the plan step ends that way; the implement step and the health job call
# it for a split that could not finish. The step becomes split, which no profile runs and the
# board shows as waiting on its children, and the worktree goes back to the pool, so its branch
# stops drifting and the pool does not shrink. The worktree is kept, and the claim's step set to
# split, when it has uncommitted changes, a run is in flight, or a live session works in it (the
# health job's process check). The branch is never forced: one with commits past the base is
# kept, and said, for a child that needs them to merge in. Each change is one events.log line and
# one comment on the item; a call that changes nothing is silent. Leaves the message in $split_msg
# and, when the worktree stays, why in $split_kept. Exit 1, changing nothing, when the item is an
# epic, has no open children, or its plan.md does not say tracker tasks.
cmd_split() {
  sp_item="$1"; split_msg=""; split_kept=""
  sp_data="$(adapter read "$sp_item" 2>/dev/null)" || { echo "flow: cannot read $sp_item, so it is not split" >&2; return 1; }
  [ "$(json_get "$sp_data" kind)" != epic ] || { echo "$sp_item is an epic: its tasks are its children, nothing to split"; return 1; }
  sp_kids="$(json_get "$sp_data" open_children)"
  [ "${sp_kids:-0}" -gt 0 ] 2>/dev/null || { echo "$sp_item has no open children, so it is not split"; return 1; }
  plan_tracker_tasks "$sp_item" || { echo "$sp_item: plan.md does not say tracker tasks, so it is not split"; return 1; }
  ! kept_whole "$sp_item" || { echo "$sp_item: the owner kept it whole, so it is not split until its plan step rewrites plan.md"; return 1; }
  sp_was="$(state_get "$sp_data" step)"
  sp_said="split into $sp_kids open child item(s), it waits on them"
  [ "$sp_was" = split ] || write_state "$sp_item" "step=split" "last_event=$(now_iso) $sp_said"
  sp_path="$(cmd_find "$sp_item")"
  if [ -z "$sp_path" ]; then
    [ "$sp_was" = split ] || split_msg="$sp_said; it holds no worktree"
  else
    sp_name="$(basename "$sp_path")"; sp_claim="$(claim_of "$sp_path")"
    sp_branch="$(json_get "$sp_claim" branch)"; sp_base="$(json_get "$sp_claim" base)"; [ -n "$sp_base" ] || sp_base="$base_branch"
    sp_procs="${procs:-${FLOW_HEALTH_PROCS:-}}"; sp_tmp=""
    if [ -z "$sp_procs" ]; then
      sp_tmp="$(mktemp)"; sp_procs="$sp_tmp"
      python3 -I "$FLOW_PLUGIN/scripts/_health.py" procs > "$sp_tmp" 2>/dev/null || : > "$sp_tmp.failed"
    fi
    if [ -f "$home/runs/$(item_slug "$sp_item").json" ]; then split_kept="a run is in flight"
    elif dirty "$sp_path"; then split_kept="it has uncommitted changes: commit or stash them; the health job then releases it"
    elif [ -n "$sp_tmp" ] && [ -f "$sp_tmp.failed" ]; then split_kept="the processes cannot be listed, so a session may be working in it"
    else
      sp_live="$(python3 -I "$FLOW_PLUGIN/scripts/_health.py" alive "$sp_procs" "$sp_item" "$sp_path" "" 2>/dev/null)"
      [ -z "$sp_live" ] || split_kept="a session works in it ($sp_live)"
    fi
    [ -z "$sp_tmp" ] || rm -f "$sp_tmp" "$sp_tmp.failed"
    if [ -n "$split_kept" ]; then
      # Through a temp file beside it: a failed write never leaves an empty claim (a free look).
      sp_new="$sp_path/.flow/claim.json.tmp.$$"
      if json_set "$sp_claim" step "$(json_string split)" > "$sp_new" && [ -s "$sp_new" ]; then mv "$sp_new" "$sp_path/.flow/claim.json"; else rm -f "$sp_new"; fi
      [ "$sp_was" = split ] && [ "$(json_get "$sp_claim" step)" = split ] || split_msg="$sp_said; $sp_name is kept: $split_kept"
    else
      sp_ahead="$(git -C "$sp_path" rev-list --count "$(base_ref "$sp_base")..refs/heads/$sp_branch" 2>/dev/null)"
      if (cmd_release "$sp_path" >/dev/null 2>&1); then
        split_msg="$sp_said; released $sp_name"
        if [ "${sp_ahead:-0}" -gt 0 ] && git -C "$main" show-ref --verify --quiet "refs/heads/$sp_branch"; then
          split_msg="$split_msg; $sp_branch keeps its $sp_ahead commit(s) past $sp_base for a child that needs them to merge in"
        fi
      else split_kept="the release failed"; split_msg="$sp_said; $sp_name is kept: $split_kept"; fi
    fi
  fi
  [ -n "$split_msg" ] || return 0
  mkdir -p "$home"
  printf '%s\t%s\tsplit\t%s\n' "$(now_iso)" "$sp_item" "$split_msg" >> "$home/events.log"
  adapter comment "$sp_item" --body "Split: $split_msg." >/dev/null 2>&1 || true
  echo "$sp_item: $split_msg"
}

# item_status <item>: open, closed, or nothing when no adapter owns the id or it cannot be read.
item_status() {
  adapter_for "$1" >/dev/null 2>&1 || return 0
  json_get "$(adapter read "$1" 2>/dev/null)" status
}

# cmd_reports <item>: the one place an item's reports live, for skills run outside next.sh. The
# claimed worktree's folder; else an existing folder in a pool worktree or the main worktree
# (a released item keeps its reports where they were written); else the main worktree's.
cmd_reports() {
  adapter_for "$1" >/dev/null 2>&1 || die "not an item id: $1 (use gh#<n> or local:<kind>/<n>)" 2
  slug="$(item_slug "$1")"
  dir=""; wt="$(cmd_find "$1")"
  if [ -n "$wt" ]; then dir="$wt/.flow/reports/$slug"
  else
    for root in $(pool_paths) "$main"; do
      [ -d "$root/.flow/reports/$slug" ] && { dir="$root/.flow/reports/$slug"; break; }
    done
  fi
  [ -n "$dir" ] || dir="$main/.flow/reports/$slug"
  mkdir -p "$dir" || die "cannot create $dir"
  printf '%s\n' "$dir"
}

cmd_tmp() {
  case "$1" in
    add)
      item="$2"; phase="$3"; slug="$(item_slug "$item")"
      wt="$(cmd_find "$item")"; [ -n "$wt" ] || die "$item has no claimed worktree" 2
      path="$home/tmp/$slug-$phase"; branch="flow/$slug-$phase"
      mkdir -p "$home/tmp"
      git -C "$wt" worktree add -q -b "$branch" "$path" "flow/$slug" || die "cannot add $path"
      printf '%s\n' "$path" ;;
    remove)
      path="$2"
      branch="$(git -C "$path" symbolic-ref --short -q HEAD)"
      dirty "$path" && die "$path has uncommitted changes. Not removing." 3
      git -C "$main" worktree remove "$path" || die "cannot remove $path"
      [ -n "$branch" ] && git -C "$main" branch -q -D "$branch" 2>/dev/null
      echo "removed $path" ;;
    *) die "usage: tmp add <item> <phase> | tmp remove <path>" 2 ;;
  esac
}

# next_pool_path: the path a new pool worktree gets. worktree_name, such as ../{repo}-wt-{n},
# names it: {repo} is the main worktree's folder, {n} the first number no pool entry and no folder
# uses; a name with no {n}, or one whose numbers all give the same idle branch, is refused (exit 2).
# Unset, it follows the last entry's name (../app-wt-2 -> ../app-wt-3) or ../<main>-wt-<n> when the
# pool is empty or named otherwise.
next_pool_path() {
  template="$(cfg worktree_name)"
  if [ -z "$template" ]; then
    last="$(cfg pool | grep . | tail -1)"
    case "$last" in
      *-wt-[0-9]*) template="${last%-wt-*}-wt-{n}" ;;
      *) template="../{repo}-wt-{n}" ;;
    esac
  fi
  case "$template" in *'{n}'*) ;; *) die "worktree_name $template has no {n}, so every new pool worktree would get the same path; add {n} to it in $(config_file)" 2 ;; esac
  repo_name="$(basename "$main" | sed 's/[\\&|]/\\&/g')"
  same_idle="$(idle_branch "$(pool_name "$template" 1)")"
  [ "$same_idle" != "$(idle_branch "$(pool_name "$template" 2)")" ] ||
    die "worktree_name $template gives every new pool worktree the idle branch $same_idle, and git checks a branch out in one worktree at a time; put {n} at the end of the last folder name in $(config_file)" 2
  n=1
  while :; do
    cand="$(pool_name "$template" "$n")"
    case "$cand" in /*) abs="$cand" ;; *) abs="$main/$cand" ;; esac
    cfg pool | grep -qx "$cand" || [ -e "$abs" ] || { printf '%s' "$cand"; return; }
    n=$((n + 1))
  done
}

# pool_name <template> <n>: the template with {repo} and {n} filled.
pool_name() { printf '%s' "$1" | sed "s|{repo}|$repo_name|g; s|{n}|$2|g"; }

# pool_add_entry <path>: append the path under pool: in config.yaml (the one key the steward
# writes). A commented placeholder entry is dropped.
pool_add_entry() {
  f="$(config_file)"; tmp="$f.tmp.$$"
  if grep -q '^pool:' "$f"; then
    awk -v entry="  - $1" '
      /^pool:/ { print; inpool = 1; next }
      inpool && /^  # - / { next }
      inpool && !/^  - / && !/^[ 	]*$/ { print entry; inpool = 0 }
      { print }
      END { if (inpool) print entry }' "$f" > "$tmp"
  else
    { cat "$f"; printf 'pool:
  - %s
' "$1"; } > "$tmp"
  fi
  mv "$tmp" "$f"
}

# run_setup <path>: copy the ignored files the config lists when missing, then run the setup
# commands there. A failing command is reported and does not undo the worktree.
run_setup() {
  p="$1"
  cfg worktree_copy | while read -r rel; do
    [ -n "$rel" ] || continue
    [ -e "$main/$rel" ] || { echo "flow: worktree_copy: $rel is not in $main; skipped" >&2; continue; }
    [ -e "$p/$rel" ] && continue
    mkdir -p "$(dirname "$p/$rel")" && cp -R "$main/$rel" "$p/$rel" && echo "copied $rel"
  done
  cfg worktree_setup | while read -r cmd; do
    [ -n "$cmd" ] || continue
    (cd "$p" && sh -c "$cmd") && echo "setup: $cmd" || echo "flow: worktree_setup failed in $p: $cmd" >&2
  done
}

# pool_worktree_add <path>: a new pool worktree on its idle branch at the base tip (detached
# when an idle branch of that name has commits of its own).
pool_worktree_add() {
  pa_branch="$(idle_branch "$1")"
  if idle_kept "$pa_branch"; then
    echo "flow: $pa_branch has commits not in $(base_ref); kept, and $(basename "$1") starts detached" >&2
    git -C "$main" worktree add -q --detach "$1" "$(base_ref)"
  else git -C "$main" worktree add -q --no-track -B "$pa_branch" "$1" "$(base_ref)"; fi
}

# pool_recreate <path>: a pool worktree whose folder is gone comes back on its idle branch at the
# base tip, with the copies and the setup. git's record of the missing folder is pruned first, or
# git would refuse the path and the idle branch that record still holds. Returns 1, with git's
# reason, when git cannot add it (a record locked against pruning, say).
pool_recreate() {
  git -C "$main" worktree prune 2>/dev/null
  pool_worktree_add "$1" || { echo "flow: cannot recreate the pool worktree $1, which is missing on disk" >&2; return 1; }
  run_setup "$1"
  echo "flow: recreated $(basename "$1"), which was missing on disk, on $(git -C "$1" symbolic-ref --short -q HEAD || echo "a detached HEAD") at $(base_ref)" >&2
}

# grow_pool: add one worktree when the pool is below pool_max; print its path. Returns 1 when the
# pool is full or git cannot add the worktree; exits 2 when next_pool_path refuses worktree_name.
grow_pool() {
  max="$(cfg_or pool_max 0)"
  count="$(cfg pool | grep -c .)"
  [ "$max" -gt "$count" ] 2>/dev/null || return 1
  rel="$(next_pool_path)" || exit
  case "$rel" in /*) abs="$rel" ;; *) abs="$main/$rel" ;; esac
  pool_worktree_add "$abs" || return 1
  pool_add_entry "$rel"
  run_setup "$abs" >&2
  echo "flow: added $rel to the pool ($((count + 1)) of $max)" >&2
  (cd "$abs" && pwd)
}

# cmd_add [path]: a new pool worktree, or a pool path missing on disk recreated in place (its
# entry is already there, so none is appended).
cmd_add() {
  rel="${1:-$(next_pool_path)}" || exit
  case "$rel" in /*) abs="$rel" ;; *) abs="$main/$rel" ;; esac
  if [ ! -e "$abs" ] && pool_paths | grep -qxF -- "$(pool_spelling "$abs")"; then
    pool_recreate "$(pool_spelling "$abs")" || die "cannot recreate worktree $rel"
    echo "recreated $rel, already in the pool in $(config_file)."; return 0
  fi
  pool_worktree_add "$abs" || die "cannot add worktree $rel"
  pool_add_entry "$rel"
  run_setup "$abs"
  echo "added $rel to the pool in $(config_file)."
}

cmd_setup() {
  p="$(resolve_path "$1")"; [ -n "$p" ] && [ -d "$p" ] || die "no worktree at $1" 2
  run_setup "$p"
}

# cmd_prune: reports outlive the release, so they pile up in every worktree. A folder goes when
# its item is closed and no worktree claims it. Open, claimed, unreadable and unknown folders stay.
cmd_prune() {
  dry=0
  while [ $# -gt 0 ]; do case "$1" in --dry-run) dry=1; shift ;; *) die "unknown option $1" 2 ;; esac; done
  known=""; removed=0; kept=0
  for root in "$main" $(pool_paths); do
    for d in "$root"/.flow/reports/*/; do
      [ -d "$d" ] || continue
      d="${d%/}"; item="$(slug_item "$(basename "$d")")"
      if [ -z "$item" ]; then echo "kept $d: not an item folder"; kept=$((kept + 1)); continue; fi
      if [ -n "$(cmd_find "$item")" ]; then kept=$((kept + 1)); continue; fi
      status="$(printf '%s' "$known" | sed -n "s|^$item=||p" | head -1)"
      if [ -z "$status" ]; then
        status="$(item_status "$item")"; [ -n "$status" ] || status="unreadable"
        known="$known$item=$status
"
      fi
      case "$status" in
        closed)
          if [ "$dry" -eq 1 ]; then echo "would remove $d ($item is closed)"
          else rm -rf "$d" && echo "removed $d ($item is closed)"; fi
          removed=$((removed + 1)) ;;
        unreadable) echo "kept $d: cannot read $item"; kept=$((kept + 1)) ;;
        *) kept=$((kept + 1)) ;;
      esac
    done
  done
  verb="removed"; [ "$dry" -eq 1 ] && verb="would remove"
  echo "prune: $verb $removed, kept $kept"
}

# cmd_sweep: merging on the host is the owner's answer to the merge gate, so nobody has to say it
# again. Each claimed worktree whose item is closed, or whose linked PR is merged, is released:
# an open merge gate clears with the PR's URL, an item still open closes (a PR into an epic
# branch does not close its issue), and the task branch goes even when squash-merged, but only
# while its tip is the PR's head, so a commit made after the merge keeps it. A worktree with
# uncommitted changes, a run in flight, or an item that cannot be read is left alone.
# --item is for the console, which runs it once it sees a gated PR leave the open list: one
# item's PR is read, not every claim's. --lock never waits: a sweep already running is enough.
cmd_sweep() {
  dry=0; only=""; lock=0
  while [ $# -gt 0 ]; do case "$1" in
    --dry-run) dry=1; shift ;;
    --lock) lock=1; shift ;;
    --item) [ $# -ge 2 ] || die "--item needs an item id" 2; only="$2"; shift 2 ;;
    *) die "unknown option $1" 2 ;;
  esac; done
  [ "$lock" -eq 0 ] || FLOW_LOCK_WAIT=0 flow_lock sweep || die "sweep skipped: the sweep lock is held" 75
  for p in $(pool_paths); do
    [ -d "$p" ] || continue
    c="$(claim_of "$p")"; it="$(json_get "$c" item)"; br="$(json_get "$c" branch)"; name="$(basename "$p")"
    [ -z "$only" ] || [ "$it" = "$only" ] || continue
    [ -n "$it" ] && adapter_for "$it" >/dev/null 2>&1 || continue
    data="$(adapter read "$it" 2>/dev/null)" || continue
    status="$(json_get "$data" status)"; gate="$(state_get "$data" gate)"; pr="$(state_get "$data" pr)"
    # A PR the pr step's worker could not record (a local item file lies outside its sandbox) is
    # found by the claim's task branch, flow/<slug>, while the item waits at the merge gate, and
    # recorded on the item.
    if [ -z "$pr" ] && [ "$gate" = merge ]; then
      gh_repo="$(cfg github.repo)"
      found="$(cd "$main" && gh pr list ${gh_repo:+-R "$gh_repo"} --head "$br" --state all --json url 2>/dev/null)" && pr="$(json_get "$found" 0.url)"
      [ -z "$pr" ] || [ "$dry" -eq 1 ] || adapter link-pr "$it" "$pr" >/dev/null || echo "flow: could not record $pr on $it" >&2
    fi
    merged=0; head=""
    if [ -n "$pr" ] && st="$("$FLOW_PLUGIN/scripts/comments.sh" state "$pr" 2>/dev/null)" && [ "$(json_get "$st" state)" = MERGED ]; then
      merged=1; head="$(json_get "$st" headRefOid)"
    fi
    [ "$status" = closed ] || [ "$merged" -eq 1 ] || continue
    why="$it is closed"; [ "$merged" -eq 1 ] && why="$pr merged"
    if [ -f "$home/runs/$(item_slug "$it").json" ]; then echo "$it: kept $name, a run is in flight"; continue; fi
    if dirty "$p"; then echo "$it: kept $name, it has uncommitted changes ($why)"; continue; fi
    if [ "$dry" -eq 1 ]; then echo "$it: would release $name ($why)"; continue; fi
    [ "$gate" = merge ] && "$FLOW_PLUGIN/scripts/gate.sh" clear "$it" "$(if [ "$merged" -eq 1 ]; then echo "merged: $pr"; else echo "closed"; fi)" >/dev/null && echo "$it: cleared the merge gate"
    [ "$status" = closed ] || adapter close "$it" --comment "Closed by flow: $pr is merged." >/dev/null || echo "flow: could not close $it" >&2
    force=""
    [ -n "$head" ] && [ "$(git -C "$p" rev-parse -q --verify "refs/heads/$br" 2>/dev/null)" = "$head" ] && force="--force"
    (cmd_release "$p" $force >/dev/null) && echo "$it: released $name ($why)"
  done
}

# --- health: the pool checked in order, claim by claim. See jobs/health.sh, which runs it.
hpy() { python3 -I "$FLOW_PLUGIN/scripts/_health.py" "$@"; }

# health_say <item> <fact>: one line per fact, on stdout and in events.log, of the kind health
# (resume when the owner resumes a run, unheld when a hold is cleared).
health_say() {
  printf '%s: %s\n' "$1" "$2"
  facts=$((facts + 1))
  [ "$dry" -eq 1 ] && return 0
  printf '%s\t%s\t%s\t%s\n' "$(now_iso)" "$([ "$1" = pool ] && echo - || echo "$1")" "${health_kind:-health}" "$2" >> "$home/events.log"
}

# health_notify <message>: a notification on the health event; notify.health: false silences it.
health_notify() {
  [ "$(cfg notify.health)" = false ] && return 0
  if [ "$dry" -eq 1 ]; then echo "would notify: $1"; return 0; fi
  "$FLOW_PLUGIN/scripts/notify.sh" --event health --no-log "$1" >/dev/null 2>&1 || true
}

# health_changed <key> <text>: true when the fact under the key is new or changed since the last
# run, and records it, so a condition that stays is said once. health_cleared <key> forgets it.
health_changed() {
  f="$home/health/$1.seen"
  [ -f "$f" ] && [ "$(cat "$f")" = "$(printf '%s' "$2")" ] && return 1
  [ "$dry" -eq 1 ] || printf '%s\n' "$2" > "$f"
  return 0
}
health_cleared() { [ "$dry" -eq 1 ] || rm -f "$home/health/$1.seen"; }

health_ago() { hpy ago "$1"; }

# health_branch_state <item> <path> <branch> <base> <pr>: bring a clean claimed worktree in step
# with its remote branch (fast-forward when only behind; push when only ahead of a branch that
# exists and jobs.health.push is true, else say it once) and with its base (merge it in once the
# branch is more than behind_base commits behind, has no PR and waits at no gate: a PR's conflicts
# are the comments job's). Leave in $health_sync the refs a merge needs an agent for, one per line: the remote
# branch when the two diverged, the base when its merge conflicts.
health_branch_state() {
  hb_item="$1"; hb_path="$2"; hb_branch="$3"; hb_base="$(base_ref "$4")"; hb_pr="$5"; health_sync=""
  [ "$(git -C "$hb_path" symbolic-ref --short -q HEAD)" = "$hb_branch" ] || return 0
  if [ "$have_remote" -eq 1 ] && git -C "$hb_path" show-ref --verify --quiet "refs/remotes/origin/$hb_branch"; then
    set -- $(git -C "$hb_path" rev-list --left-right --count "HEAD...origin/$hb_branch")
    hb_ahead="${1:-0}"; hb_behind="${2:-0}"
    [ "$hb_ahead" -gt 0 ] && [ "$hb_behind" -eq 0 ] || health_cleared "unpushed-$(item_slug "$hb_item")"
    if [ "$hb_ahead" -eq 0 ] && [ "$hb_behind" -gt 0 ]; then
      if [ "$dry" -eq 1 ]; then health_say "$hb_item" "would fast-forward $hb_branch by $hb_behind commit(s)"
      elif git -C "$hb_path" merge -q --ff-only "origin/$hb_branch" >/dev/null 2>&1; then health_say "$hb_item" "fast-forwarded $hb_branch by $hb_behind commit(s) from origin"
      else health_say "$hb_item" "could not fast-forward $hb_branch"; fi
    elif [ "$hb_ahead" -gt 0 ] && [ "$hb_behind" -eq 0 ]; then
      if [ "$push" != true ]; then
        health_changed "unpushed-$(item_slug "$hb_item")" "$hb_ahead" && health_say "$hb_item" "$hb_branch is $hb_ahead commit(s) ahead of origin; not pushed (jobs.health.push is off)"
      elif [ "$dry" -eq 1 ]; then health_say "$hb_item" "would push $hb_ahead commit(s) of $hb_branch"
      elif git -C "$hb_path" push -q origin "refs/heads/$hb_branch:refs/heads/$hb_branch" >/dev/null 2>&1; then health_say "$hb_item" "pushed $hb_ahead commit(s) of $hb_branch"
      else health_say "$hb_item" "could not push $hb_branch"; fi
    elif [ "$hb_ahead" -gt 0 ]; then
      health_sync="origin/$hb_branch
"
    fi
  fi
  [ -z "$hb_pr" ] || return 0
  hb_late="$(git -C "$hb_path" rev-list --count "HEAD..$hb_base" 2>/dev/null)"
  [ "${hb_late:-0}" -gt "$behind_base" ] || return 0
  # A diverged branch goes to the agent whole: the base merge waits for the remote one.
  if [ -n "$health_sync" ]; then health_sync="$health_sync$hb_base
"; return 0; fi
  # A branch waiting at a gate is the owner's to look at: it is merged once the gate clears.
  [ -z "$health_gate" ] || return 0
  if [ "$dry" -eq 1 ]; then health_say "$hb_item" "would merge $hb_base into $hb_branch ($hb_late commits behind)"; return 0; fi
  # Under the pick lock, so a next that starts a step here waits for the merge to finish.
  flow_lock pick || return 0
  if [ -f "$home/runs/$(item_slug "$hb_item").json" ]; then flow_unlock; return 0; fi
  if git -C "$hb_path" merge -q --no-edit -m "chore: merge $hb_base into $hb_branch" "$hb_base" >/dev/null 2>&1; then
    health_say "$hb_item" "merged $hb_base into $hb_branch ($hb_late commits behind)"
  else
    git -C "$hb_path" merge --abort >/dev/null 2>&1
    health_sync="$hb_base
"
  fi
  flow_unlock
}

# health_free <path>: a free pool worktree sits on its idle branch at the base branch tip; one
# left detached (a pool from before 1.24.0) moves onto it. A dirty one goes through
# health_free_dirty first. One on another branch and one holding commits the base lacks are only
# said.
health_free() {
  hf_name="$(basename "$1")"
  if dirty "$1"; then health_free_dirty "$1" || return 0; fi
  health_cleared "free-$hf_name"
  hf_idle="$(idle_branch "$1")"; hf_on="$(git -C "$1" symbolic-ref --short -q HEAD)"
  hf_tip="$(git -C "$1" rev-parse -q --verify "$(base_ref)" 2>/dev/null)"; hf_head="$(git -C "$1" rev-parse -q --verify HEAD 2>/dev/null)"
  [ -n "$hf_tip" ] || return 0
  [ "$hf_tip" != "$hf_head" ] || [ -z "$hf_on" ] || return 0
  if [ -n "$hf_on" ] && [ "$hf_on" != "$hf_idle" ]; then
    health_changed "free-$hf_name-branch" on && health_say pool "$hf_name is free but on the branch $hf_on, so it is not moved"
  elif ! git -C "$1" merge-base --is-ancestor "$hf_head" "$hf_tip" 2>/dev/null; then
    health_changed "free-$hf_name-branch" off && health_say pool "$hf_name is free but its commit is not in $base_branch, so it is not moved"
  elif [ -z "$hf_on" ] && idle_kept "$hf_idle"; then
    health_changed "free-$hf_name-branch" kept && health_say pool "$hf_name is free and detached, but $hf_idle has commits not in $base_branch, so it is not moved onto it"
  elif [ -z "$hf_on" ]; then
    if [ "$dry" -eq 1 ]; then health_say pool "would move free $hf_name onto $hf_idle at $base_branch"
    elif park "$1"; then health_say pool "moved free $hf_name onto $hf_idle at $base_branch"
    else health_say pool "could not move free $hf_name onto $hf_idle"; fi
  elif [ "$dry" -eq 1 ]; then health_say pool "would fast-forward free $hf_name to $base_branch"
  elif git -C "$1" merge -q --ff-only "$hf_tip" >/dev/null 2>&1; then health_say pool "fast-forwarded free $hf_name to $base_branch"
  else health_say pool "could not fast-forward free $hf_name"; fi
}

# health_free_dirty <path>: uncommitted changes in a free worktree that the base branch's history
# already holds, path by path (scripts/_redundant.py), are said once, then discarded by the next
# run that finds them unchanged with no session working there; it returns 0 when it discarded
# them. The discard checks again and restores only the checked paths, so .flow/ is never touched.
# Changes holding anything of their own are kept, and said once per first such path.
health_free_dirty() {
  hd_name="$(basename "$1")"
  hd_found="$(python3 -I "$FLOW_PLUGIN/scripts/_redundant.py" "$1" "$(base_ref)" 2>/dev/null)"
  case "$hd_found" in
    redundant*) ;;
    *) hd_why="${hd_found#kept?}"; hd_why="${hd_why:-they could not be checked}"
       health_changed "free-$hd_name" "dirty: $hd_why" && health_say pool "$hd_name is free but has uncommitted changes, so no claim can use it: $hd_why"
       return 1 ;;
  esac
  hd_print="$(printf '%s' "$hd_found" | cut -f2)"; hd_count="$(printf '%s' "$hd_found" | cut -f3)"
  if [ "$(cat "$home/health/free-$hd_name.seen" 2>/dev/null)" != "redundant $hd_print" ]; then
    health_changed "free-$hd_name" "redundant $hd_print" && health_say pool "$hd_name is free but has $hd_count uncommitted change(s), each already in $base_branch's history; the next health run discards them if they stay unchanged and no session works there"
    return 1
  fi
  # A destructive step: a session that called health from inside the worktree counts too.
  [ "$procs_ok" -eq 1 ] && [ -z "$(hpy present "$procs" "" "$1" "")" ] || return 1
  if [ "$dry" -eq 1 ]; then health_say pool "would discard the $hd_count uncommitted change(s) in free $hd_name, each already in $base_branch's history"; return 1; fi
  hd_done="$(python3 -I "$FLOW_PLUGIN/scripts/_redundant.py" "$1" "$(base_ref)" --discard "$hd_print" 2>/dev/null)"
  case "$hd_done" in
    discarded*)
      health_say pool "discarded the $hd_count uncommitted change(s) in free $hd_name, each already in $base_branch's history"
      health_notify "Discarded the $hd_count uncommitted change(s) in free $hd_name: each was already in $base_branch's history, so nothing is lost. A claim can use it again."
      return 0 ;;
  esac
  hd_why="${hd_done#kept?}"
  health_say pool "could not discard the uncommitted changes in free $hd_name${hd_why:+: $hd_why}"
  return 1
}

# health_missing <path>: a pool path missing on disk is no claim's and no run's; the next claim
# recreates it. Said once while it holds, with the command that recreates it now.
health_missing() {
  hm_name="$(basename "$1")"
  health_changed "missing-$hm_name" missing || return 0
  health_say pool "$hm_name is in the pool but missing on disk; the next claim recreates it on $(idle_branch "$1") at $base_branch, or recreate it now: steward.sh add $1"
}

# health_resume <item> <step> <path>: start the step again in the background, where the dead run
# left it, on $resume_host with $resume_model and $resume_effort when set, at most max_resumes times in a row while the step does not advance; then escalate. The
# note for the resumed step goes in resume.md, which next.sh puts in that one brief and removes.
health_resume() {
  hr_item="$1"; hr_step="$2"; hr_path="$3"; hr_file="$home/health/$(item_slug "$1").resume"
  hr_n=0; hr_last=""
  [ -f "$hr_file" ] && read -r hr_n hr_last < "$hr_file"
  [ "$hr_last" = "$hr_step" ] || hr_n=0
  if [ "$hr_n" -ge "$max_resumes" ]; then
    if [ "$dry" -eq 1 ]; then health_say "$hr_item" "would raise an escalation gate: the run of $hr_step died $hr_n times in a row"; return 0; fi
    health_say "$hr_item" "the run of $hr_step died $hr_n times in a row without the step advancing; escalation gate raised"
    "$FLOW_PLUGIN/scripts/gate.sh" raise "$hr_item" escalation "The run of step $hr_step died $hr_n times in a row, and the health job resumed it each time without the step advancing. $(basename "$hr_path") keeps its commits and uncommitted changes untouched. Read $home/log, then clear the gate to let the flow try again." --raised-by "health job" >/dev/null 2>&1 || true
    rm -f "$hr_file"; health_gate=escalation
    return 0
  fi
  if [ "$dry" -eq 1 ]; then health_say "$hr_item" "would resume $hr_step on $resume_host (attempt $((hr_n + 1)) of $max_resumes)"; return 0; fi
  if ! host_check "$resume_host" >/dev/null 2>&1; then health_say "$hr_item" "cannot resume $hr_step: $resume_host is not installed"; return 0; fi
  hr_n=$((hr_n + 1)); printf '%s %s\n' "$hr_n" "$hr_step" > "$hr_file"
  mkdir -p "$health_reports" && printf 'The previous run of step %s died. Health job resume %s of %s: this worktree holds its commits and uncommitted changes. Read git status and git log, continue from there, and discard nothing.\n' "$hr_step" "$hr_n" "$max_resumes" > "$health_reports/resume.md"
  health_say "$hr_item" "resumed $hr_step on $resume_host (attempt $hr_n of $max_resumes)"
  hr_run="$FLOW_PLUGIN/templates/run-unattended.sh"; hr_log="$home/log/resume-$(item_slug "$hr_item").log"
  if [ "$wait_for_resume" -eq 1 ]; then "$hr_run" "$resume_host" "$hr_item" ${resume_model:+--model "$resume_model"} ${resume_effort:+--effort "$resume_effort"} >> "$hr_log" 2>&1
  else hpy spawn "$hr_log" "$hr_run" "$resume_host" "$hr_item" ${resume_model:+--model "$resume_model"} ${resume_effort:+--effort "$resume_effort"} >/dev/null; fi
}

# health_claim <path>: every check of one claimed worktree, in order: the heartbeat, the empty
# claim, the resume of cut-off work, the branch sync, the notes for the next step.
health_claim() {
  p="$1"; name="$(basename "$p")"; c="$(claim_of "$p")"; it="$(json_get "$c" item)"; br="$(json_get "$c" branch)"
  bs="$(json_get "$c" base)"; [ -n "$bs" ] || bs="$base_branch"
  claims=$((claims + 1))
  if [ "$procs_ok" -eq 0 ]; then holders="$holders$name $it not checked: no process list
"; return 0; fi
  if ! adapter_for "$it" >/dev/null 2>&1; then holders="$holders$name $it a session outside the flow
"; return 0; fi
  slug="$(item_slug "$it")"; rec="$home/runs/$slug.json"; health_reports="$p/.flow/reports/$slug"; health_gate=""; health_sync=""
  if ! data="$(adapter read "$it" 2>/dev/null)"; then holders="$holders$name $it unreadable
"; health_say "$it" "cannot read it on the tracker; $name is left alone"; return 0; fi
  step="$(state_get "$data" step)"; health_gate="$(state_get "$data" gate)"
  [ "$health_gate" != none ] || health_gate=""
  [ -n "$health_gate" ] || [ ! -f "$home/gates/$slug.json" ] || health_gate="$(json_get "$(cat "$home/gates/$slug.json")" gate)"
  state=none; dead=0; pid=""; started=0
  if [ -f "$rec" ]; then
    pid="$(json_get "$(cat "$rec")" pid)"; started="$(hpy epoch "$(json_get "$(cat "$rec")" started)")"
    if [ -n "$(hpy alive "$procs" "$it" "$p" "$pid")" ]; then state=running
    elif [ $((now - started)) -le "$grace" ]; then state=running
    else state=dead; fi
  elif [ -n "$(hpy alive "$procs" "$it" "$p" "")" ]; then state=running; fi
  if [ "$state" = running ]; then
    running=$((running + 1)); holders="$holders$name $it running
"; return 0
  fi
  last="$(hpy activity "$p" "$health_reports" "$home/events.log" "$it")"
  if [ "$state" = dead ]; then
    dead=1
    if [ "$dry" -eq 1 ]; then health_say "$it" "would clear the dead run of ${step:-?} (record $(health_ago "$started"), no process; last activity $(health_ago "$last"))"
    else
      rm -f "$rec"
      adapter write-state "$it" "last_event=$(now_iso) health: cleared the dead run of ${step:-?}" >/dev/null 2>&1 || true
      health_say "$it" "dead run of ${step:-?} cleared (record $(health_ago "$started"), no process; last activity $(health_ago "$last"))"
    fi
  fi
  health_held=""
  [ "$health_gate" != merge ] || health_review "$it" "$(state_get "$data" pr)"
  if [ -n "$health_held" ]; then reviewing=$((reviewing + 1)); holders="$holders$name $it its PR is $health_held, so the merge gate waits on the reviewers
"
  elif [ -n "$health_gate" ]; then gated=$((gated + 1)); holders="$holders$name $it waiting at the $health_gate gate
"; fi
  ahead="$(git -C "$p" rev-list --count "$(base_ref "$bs")..HEAD" 2>/dev/null)"; ahead="${ahead:-0}"
  results="$(ls "$health_reports"/*.json 2>/dev/null | head -1)"
  isdirty=0; dirty "$p" && isdirty=1
  [ -z "$health_gate" ] || health_at_gate "$it" "$p" "$isdirty" "$(state_get "$data" pr)"
  claimed="$(hpy epoch "$(json_get "$c" claimed_at)")"
  quiet_for=$((now - last)); [ "$last" -gt "$claimed" ] || quiet_for=$((now - claimed))
  if [ -z "$health_gate" ] && [ "$isdirty" -eq 0 ] && [ "$ahead" -eq 0 ] && [ -z "$results" ] && [ "$quiet_for" -gt "$grace" ]; then
    health_empty "$it" "$p" "$rec" "$last"; [ "$released" -eq 1 ] && return 0
  fi
  if [ -z "$health_gate" ] && [ "$dead" -eq 1 ] && { [ "$isdirty" -eq 1 ] || [ "$ahead" -gt 0 ] || [ -n "$results" ]; }; then
    health_branch_notes "$it" "$p" "$br" "$bs" "$isdirty" "$(state_get "$data" pr)"
    health_resume "$it" "${step:-}" "$p"
    [ -z "$health_gate" ] || { gated=$((gated + 1)); holders="$holders$name $it waiting at the $health_gate gate
"; return 0; }
    holders="$holders$name $it dead run, resumed
"; return 0
  fi
  # A split the plan step could not finish (made before flow 1.19.0, or kept for uncommitted
  # changes or a live session) still holds its worktree: finish it here, after a dead run had its
  # resume. Only at step plan or split, with open children and a plan.md that says tracker tasks.
  if [ -z "$health_gate" ] && { [ "$step" = plan ] || [ "$step" = split ]; } && [ "$(json_get "$data" kind)" != epic ] &&
     [ "$(json_get "$data" open_children)" -gt 0 ] 2>/dev/null && plan_tracker_tasks "$it" && ! kept_whole "$it"; then
    if [ "$dry" -eq 1 ]; then health_say "$it" "would finish the split: step split, release $name unless it must stay"; return 0; fi
    cmd_split "$it" >/dev/null
    [ -z "$split_msg" ] || { echo "$it: $split_msg"; facts=$((facts + 1)); }
    if [ ! -f "$p/.flow/claim.json" ]; then claims=$((claims - 1)); claimable=$((claimable + 1)); return 0; fi
    holders="$holders$name $it split, kept: ${split_kept:-see events.log}
"; return 0
  fi
  [ -n "$health_gate" ] || holders="$holders$name $it $([ "$isdirty" -eq 1 ] && echo "uncommitted changes" || echo "no run; the next job continues it")
"
  health_branch_notes "$it" "$p" "$br" "$bs" "$isdirty" "$(state_get "$data" pr)"
}

# health_at_gate <item> <path> <dirty> <pr>: a gate is the owner's, but two things under it are
# not theirs to find alone, each said and notified once while it holds. Uncommitted changes in
# the worktree (an interrupted run left them), and, at the merge gate, review threads on the PR
# still awaiting a reply (comments.sh activity), which the comments job addresses next.
health_at_gate() {
  hg_slug="$(item_slug "$1")"; hg_name="$(basename "$2")"
  if [ "$3" -eq 1 ]; then
    if health_changed "gate-dirty-$hg_slug" "$health_gate"; then
      health_say "$1" "waits at the $health_gate gate with uncommitted changes in $hg_name: an interrupted run left them; the next comments pass continues from them, or commit or discard them yourself"
      health_notify "$1 waits at the $health_gate gate with uncommitted changes in $hg_name: an interrupted run left them. The next comments pass continues from them, or commit or discard them yourself."
    fi
  else health_cleared "gate-dirty-$hg_slug"; fi
  hg_wait=""
  if [ "$health_gate" = merge ] && [ -n "$4" ]; then
    hg_act="$("$FLOW_PLUGIN/scripts/comments.sh" activity "$4" 2>/dev/null)" && hg_wait="$(json_list "$hg_act" awaiting | tr '\n' ' ' | sed 's/ $//')"
  fi
  if [ -n "$hg_wait" ]; then
    hg_n="$(printf '%s\n' $hg_wait | grep -c .)"; hg_pr="${4##*/}"
    if health_changed "gate-awaiting-$hg_slug" "$hg_wait"; then
      health_say "$1" "PR #$hg_pr has $hg_n unresolved review thread(s) awaiting a reply while $1 waits at the merge gate; the comments job addresses them next pass"
      health_notify "PR #$hg_pr has $hg_n unresolved review thread(s) awaiting a reply while $1 waits at the merge gate. The comments job addresses them next pass."
    fi
  else health_cleared "gate-awaiting-$hg_slug"; fi
}

# health_review <item> <pr>: a PR at the merge gate that is still in review is not the owner's to
# merge yet: health_held says why ("in review", "changes requested"), empty when only the merge is
# left. The verdict goes to <home>/reviews/<n>.review.json for the console. A reviewer that replied
# it cannot review here (Codex with no environment for the repo) would leave the gate waiting on a
# review that never comes, so the owner is told, once while it holds.
health_review() {
  hv_slug="$(item_slug "$1")"; hv_n="$(printf '%s' "$2" | sed 's|.*/||; s/^#//')"
  [ -n "$hv_n" ] || return 0
  hv_state="$("$FLOW_PLUGIN/scripts/comments.sh" state "$2" 2>/dev/null)" || return 0
  [ "$(json_get "$hv_state" state)" = OPEN ] || return 0
  "$FLOW_PLUGIN/scripts/comments.sh" reviews "$2" > "$home/health/.reviews.$$" 2>/dev/null || : > "$home/health/.reviews.$$"
  hv_record=""
  if [ "$dry" -eq 0 ]; then mkdir -p "$home/reviews"; hv_record="$home/reviews/$hv_n.review.json"; health_records="$health_records $hv_n.review.json"; fi
  hv_out="$(hpy review "$hv_state" "$home/health/.reviews.$$" ${hv_record:+"$hv_record"})"; rm -f "$home/health/.reviews.$$"
  case "$(printf '%s\n' "$hv_out" | sed -n 's/^state	//p')" in
    changes-requested) health_held="changes requested" ;;
    in-review) health_held="in review"; hv_wait="$(printf '%s\n' "$hv_out" | sed -n 's/^waiting	//p')"; [ -z "$hv_wait" ] || health_held="in review (waiting on $hv_wait)" ;;
  esac
  [ -z "$health_held" ] || health_in_review="$health_in_review $hv_slug "
  hv_cannot="$(printf '%s\n' "$hv_out" | sed -n 's/^cannot	//p')"
  if [ -z "$hv_cannot" ]; then health_cleared "gate-cannot-$hv_slug"; return 0; fi
  health_changed "gate-cannot-$hv_slug" "$hv_cannot" || return 0
  while IFS="$(printf '\t')" read -r hv_who hv_said; do
    hv_msg="$hv_who cannot review PR #$hv_n: it replied \"$hv_said\". $1 waits at the merge gate without that review; set $hv_who up for this repository, or drop it from reviews.reviewers, then merge or ask again"
    health_say "$1" "$hv_msg"
    health_notify "$hv_msg."
  done <<HV
$hv_cannot
HV
}

# health_branch_notes <item> <path> <branch> <base> <dirty> <pr>: the branch sync for a worktree
# with no live run and a clean tree. A merge only an agent can make goes in sync.md in the item's
# reports, where next.sh finds it and runs the sync step before the item's own step. No
# notification: the sync step raises a gate when the owner has to choose. A sync note can also come
# from elsewhere (the Brain Console hands a conflicted merge to the flow the same way), so the
# health job removes one only once every ref it names is merged into the branch, and a rewrite
# keeps the refs already in the note that are not merged yet (or do not resolve).
health_branch_notes() {
  [ "$5" -eq 0 ] || { health_sync=""; return 0; }
  health_branch_state "$1" "$2" "$3" "$4" "$6"
  [ "$dry" -eq 1 ] || rm -f "$health_reports/health.md"
  hn_slug="$(item_slug "$1")"
  health_note_refs "$2" "$3"
  if [ -n "$health_sync" ]; then
    if health_changed "branch-$hn_slug" "$health_sync"; then
      health_say "$1" "$3 needs $(printf '%s' "$health_sync" | sed '$!s/$/ and/' | tr '\n' ' ')merged in, which the health job cannot do cleanly; the sync step does it on the item's next run"
    fi
    hn_all="$health_sync"
    for hn_ref in $hn_open $hn_bad; do
      printf '%s' "$hn_all" | grep -qxF -- "$hn_ref" || hn_all="$hn_all$hn_ref
"
    done
    [ "$dry" -eq 1 ] || { mkdir -p "$health_reports" && printf '%s' "$hn_all" > "$health_reports/sync.md"; }
    return 0
  fi
  health_cleared "branch-$hn_slug"
  [ -f "$health_reports/sync.md" ] || { health_cleared "syncnote-$hn_slug"; return 0; }
  if [ -n "$hn_bad" ]; then
    if health_changed "syncnote-$hn_slug" "$hn_bad"; then
      health_say "$1" "the sync note for $3 names $(printf '%s' "$hn_bad" | tr ' ' '\n' | grep . | sed '$!s/$/ and/' | tr '\n' ' ')which does not resolve; it is kept, and the sync step escalates on it"
    fi
  elif [ -z "$hn_open" ]; then
    health_cleared "syncnote-$hn_slug"
    if [ "$dry" -eq 1 ]; then health_say "$1" "would clear the sync note for $3: every ref it names is merged in"
    else rm -f "$health_reports/sync.md"; health_say "$1" "cleared the sync note for $3: every ref it names is merged in"; fi
  else health_cleared "syncnote-$hn_slug"; fi
}

# health_note_refs <path> <branch>: read the item's sync.md into hn_open (refs that resolve and are
# not merged into the branch yet) and hn_bad (refs that do not resolve), space-separated.
health_note_refs() {
  hn_open=""; hn_bad=""
  [ -f "$health_reports/sync.md" ] || return 0
  for hn_ref in $(cat "$health_reports/sync.md"); do
    if ! git -C "$1" rev-parse -q --verify "$hn_ref^{commit}" >/dev/null 2>&1; then hn_bad="$hn_bad $hn_ref"
    elif ! git -C "$1" merge-base --is-ancestor "$hn_ref" "refs/heads/$2" 2>/dev/null; then hn_open="$hn_open $hn_ref"; fi
  done
}

# health_empty <item> <path> <record> <last activity>: release a claim that holds nothing, under
# the pick lock so a next that is claiming it right now wins.
health_empty() {
  released=0
  if [ "$dry" -eq 1 ]; then
    health_say "$1" "would release the empty claim on $name (no run, no commits past $bs, nothing changed since $(health_ago "$4"))"
    released=1; claims=$((claims - 1)); claimable=$((claimable + 1)); return 0
  fi
  flow_lock pick || { health_say "$1" "$name looks empty but the pick lock is busy; left for the next run"; return 0; }
  if [ ! -f "$3" ] && [ -f "$2/.flow/claim.json" ] && (cmd_release "$2" >/dev/null 2>&1); then
    health_say "$1" "released the empty claim on $name (no run, no commits past $bs, nothing changed since $(health_ago "$4"))"
    released=1; claims=$((claims - 1)); claimable=$((claimable + 1))
  else health_say "$1" "could not release the empty claim on $name"; fi
  flow_unlock
}

# health_gates: a gate pending longer than gate_reminder says so once per interval.
health_gates() {
  for f in "$home"/gates/*.json; do
    [ -f "$f" ] || continue
    g="$(cat "$f")"; gi="$(json_get "$g" item)"; gt="$(json_get "$g" gate)"; since="$(hpy epoch "$(json_get "$g" time)")"
    # A merge gate whose PR is still in review waits on the reviewers, not on the owner.
    case "$health_in_review" in *" $(item_slug "$gi") "*) [ "$gt" = merge ] && continue ;; esac
    waiting=$((waiting + 1))
    [ $((now - since)) -gt "$reminder" ] || continue
    rf="$home/health/$(item_slug "$gi").remind"; sent=0; sent_gate=""
    [ -f "$rf" ] && read -r sent_gate sent < "$rf"
    [ "$sent_gate" = "$gt" ] && [ $((now - sent)) -lt "$reminder" ] && continue
    msg="waiting $(health_ago "$since" | sed 's/ ago$//') at the $gt gate: $(json_get "$g" message | head -1)"
    health_say "$gi" "$msg"
    health_notify "$gi $msg. Answer with: flow:gate $gi \"<answer>\""
    [ "$dry" -eq 1 ] || printf '%s %s\n' "$gt" "$now" > "$rf"
  done
  for rf in "$home"/health/*.remind; do
    [ -f "$rf" ] || continue
    [ -f "$home/gates/$(basename "$rf" .remind).json" ] || { [ "$dry" -eq 1 ] || rm -f "$rf"; }
  done
}

# health_splits: an open item with nothing left to run is the owner's to close: a split item whose
# children are all closed, or one whose every step ran and that waits at no gate (its PR was merged
# by hand, or its merge gate cleared without the sweep closing it). Say each once and notify.
health_splits() {
  hs_rows="$(python3 -I -c '
import json, sys
for line in sys.stdin:
    if line.strip():
        for i in json.loads(line):
            s = i.get("state") or {}
            if s.get("step") == "split" and not i.get("open_children"): print("split=" + i["id"])
            elif s.get("step") == "done" and s.get("gate", "none") in ("", "none"): print("done=" + i["id"])' < "$health_items")"
  hs_keys=""
  for hs_row in $hs_rows; do   # no pipe: health_say counts a finding in this shell
    hs_why="${hs_row%%=*}"; hs_id="${hs_row#*=}"
    if [ "$hs_why" = split ]; then
      hs_key="split-done-$(item_slug "$hs_id")"; hs_keys="$hs_keys $hs_key"
      health_changed "$hs_key" closed || continue
      health_say "$hs_id" "split, and every child is closed: close it"
      health_notify "$hs_id is split and every child is closed. Close it."
    else
      hs_key="step-done-$(item_slug "$hs_id")"; hs_keys="$hs_keys $hs_key"
      health_changed "$hs_key" open || continue
      health_say "$hs_id" "done (every step ran) and still open: merge or close it"
      health_notify "$hs_id is done (every step ran) and still open. Merge or close it."
    fi
  done
  # An item that left the state (closed, or sent back to a step) is forgotten, so it is said
  # again if it comes back.
  for hs_f in "$home"/health/split-done-*.seen "$home"/health/step-done-*.seen; do
    [ -f "$hs_f" ] || continue
    case " $hs_keys " in *" $(basename "$hs_f" .seen) "*) ;; *) health_cleared "$(basename "$hs_f" .seen)" ;; esac
  done
}

# health_list: every tracker's open items, one JSON list per line, in $health_items, which
# health_splits and health_holds read; the trackers whose list failed go in $health_list_failed.
health_list() {
  health_items="$home/health/.items.$$"; health_list_failed=""
  for a in $health_trackers; do
    if hl_out="$(adapter list "$a" 2>/dev/null)"; then printf '%s\n' "$hl_out"
    else health_list_failed="$health_list_failed $a "; fi
  done > "$health_items"
}

# health_holds: a planned hold (state.held_by and held_reason) that is stale or wrong is cleared,
# a line each and an `unheld` line in events.log: the holder cannot be read or found, holds no
# worktree and has no run, or its changes no longer share a path with the held item's (touches
# stand in for changes not recorded; with neither, the hold stays); a hold on the item itself; in a cycle, the newest hold. A hold whose holder closed is left for
# next.sh, which releases it with the merge note. A valid hold waiting past a day (from its
# last `held` line in events.log; none counts as old) is said and notified once, so the owner sees
# it. Only the holders no tracker list holds are read, one read each; a holder whose tracker's list
# failed this run and whose read fails too keeps its holds as they are.
health_holds() {
  hh_reads="$home/health/.reads.$$"; hh_claims="$home/health/.claims.$$"; hh_out="$home/health/.holds.$$"
  for hh_p in $(pool_paths); do json_get "$(claim_of "$hh_p")" item; echo; done | grep . > "$hh_claims"
  : > "$hh_reads"
  for hh_h in $(hpy holders "$health_items"); do
    hh_a="$(adapter_for "$hh_h" 2>/dev/null)"
    if [ -n "$hh_a" ] && hh_data="$(adapter read "$hh_h" 2>/dev/null)" && [ -n "$hh_data" ]; then
      printf '%s\n' "$hh_data" | tr -d '\n' >> "$hh_reads"
    else
      case "$health_list_failed" in *" $hh_a "*) hh_why=skip ;; *) hh_why=unreadable ;; esac
      json_obj "id=$hh_h" "$hh_why:=true" >> "$hh_reads"
    fi
    echo >> "$hh_reads"
  done
  hh_keys=""
  hpy holds "$health_items" "$hh_reads" "$hh_claims" "$home/runs" "$home/events.log" 86400 > "$hh_out"
  while IFS="$(printf '\t')" read -r hh_what hh_it hh_by hh_a hh_b; do   # no pipe: health_say counts here
    if [ "$hh_what" = clear ]; then
      if [ "$dry" -eq 1 ]; then health_say "$hh_it" "would clear its hold behind $hh_by: $hh_a"
      elif adapter write-state "$hh_it" held_by= held_reason= >/dev/null 2>&1; then
        health_kind=unheld; health_say "$hh_it" "no longer held behind $hh_by: $hh_a"; health_kind=""
      else health_say "$hh_it" "could not clear its hold behind $hh_by ($hh_a)"; fi
      continue
    fi
    hh_key="held-old-$(item_slug "$hh_it")"; hh_keys="$hh_keys $hh_key"
    health_changed "$hh_key" "$hh_by" || continue
    if [ "$hh_a" != - ]; then hh_msg="has waited $((hh_a / 3600))h behind $hh_by"
    else hh_msg="has waited behind $hh_by since before events.log dates it"; fi
    hh_msg="$hh_msg: ${hh_b:-no reason given}"
    health_say "$hh_it" "$hh_msg"
    health_notify "$hh_it $hh_msg. It is released once $hh_by closes."
  done < "$hh_out"
  rm -f "$hh_out" "$hh_reads" "$hh_claims"
  for hh_f in "$home"/health/held-old-*.seen; do
    [ -f "$hh_f" ] || continue
    case " $hh_keys " in *" $(basename "$hh_f" .seen) "*) ;; *) health_cleared "$(basename "$hh_f" .seen)" ;; esac
  done
}

# health_pressure: every worktree is claimed and the last next run could not start; say who holds
# each one and why, once until the pool has room again.
health_pressure() {
  mark="$home/health/pool-full"
  entries="$(pool_paths | grep -c .)"; max="$(cfg_or pool_max 0)"
  if [ "$claimable" -eq 0 ] && [ "$entries" -ge "$max" ] && hpy last-next "$home/log" | grep -q 'no free worktree'; then
    [ ! -f "$mark" ] || return 0
    msg="the pool is full ($claims of $entries worktrees claimed, pool_max $max) and the next job has no worktree to start in. $(printf '%s' "$holders" | sed 's/^\([^ ]*\) \([^ ]*\) /\1 holds \2: /' | tr '\n' ';')"
    health_say pool "$msg"
    health_notify "$msg"
    [ "$dry" -eq 1 ] || : > "$mark"
  else
    [ "$dry" -eq 1 ] || rm -f "$mark"
  fi
}

# health_next_runs: a next worker whose last runs in a row all waited out the pick lock, or all
# ended as if done without one step, is doing no work and saying nothing loud: say it once per
# streak, from two runs on, and forget it once a run ends another way.
health_next_runs() {
  hn_keys=""
  hpy next-streaks "$home/log" > "$home/health/.next-streaks.$$"
  while IFS="$(printf '\t')" read -r hn_job hn_kind hn_n hn_text; do
    [ "${hn_n:-0}" -ge 2 ] 2>/dev/null || continue
    hn_keys="$hn_keys next-$hn_kind-$hn_job"
    health_changed "next-$hn_kind-$hn_job" streak || continue
    if [ "$hn_kind" = lock ]; then
      hn_msg="$hn_job waited out the pick lock on its last $hn_n runs in a row: another worker held the pick for longer than the lock wait each time, so the tracker listing is slow or a pick is stuck"
    else
      hn_msg="$hn_job ended without running a step on its last $hn_n runs in a row (last: $hn_text)"
    fi
    health_say pool "$hn_msg"
    health_notify "$hn_msg"
  done < "$home/health/.next-streaks.$$"
  rm -f "$home/health/.next-streaks.$$"
  for hn_f in "$home"/health/next-lock-*.seen "$home"/health/next-nostep-*.seen; do
    [ -f "$hn_f" ] || continue
    case " $hn_keys " in *" $(basename "$hn_f" .seen) "*) ;; *) health_cleared "$(basename "$hn_f" .seen)" ;; esac
  done
}

# health_settings: the jobs.health settings and the host library; a bad setting exits 2.
# session_rows <procs file> <stale seconds>: _health.py sessions over the main worktree and every
# pool worktree on disk, each row followed by the item the worktree's claim holds (or -).
session_rows() {
  sr_old="$IFS"; IFS='
'
  # shellcheck disable=SC2046
  set -- "$1" "$2" "$main" $(pool_paths | while read -r sr_p; do [ -d "$sr_p" ] && printf '%s\n' "$sr_p"; done)
  IFS="$sr_old"
  hpy sessions "$@" | while IFS="$(printf '\t')" read -r sr_pid sr_host sr_kind sr_dir sr_state sr_secs sr_stale; do
    sr_item="$(json_get "$(claim_of "$sr_dir")" item)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$sr_pid" "$sr_host" "$sr_kind" "$sr_dir" "$sr_state" "$sr_secs" "$sr_stale" "${sr_item:--}"
  done
}

# session_how <state> <seconds>: "busy", "idle 3d 2h", or "running 7d 2h" for a host with no status.
session_how() {
  case "$1" in busy) echo busy ;; idle) echo "idle $(hpy ago "$(($(date +%s) - $2))" | sed 's/ ago$//')" ;;
    *) echo "running $(hpy ago "$(($(date +%s) - $2))" | sed 's/ ago$//')" ;; esac
}

# health_sessions: a claude or codex session idle in the main worktree or the pool past
# jobs.health.stale_session (no status: alive that long) is said once while it stays, with the
# command that ends it. One in a claimed worktree also holds the item's PR back from the comments
# job, which skips a worktree another session works in, so the line says that too.
health_sessions() {
  hs_keys=""
  session_rows "$procs" "$stale_session" > "$home/health/.sessions.$$"
  while IFS="$(printf '\t')" read -r hs_pid hs_host hs_kind hs_dir hs_state hs_secs hs_stale hs_item; do
    [ "$hs_stale" = 1 ] || continue
    hs_keys="$hs_keys stale-session-$hs_pid"
    health_changed "stale-session-$hs_pid" stale || continue
    hs_msg="$hs_host process $hs_pid ($hs_kind) in $(basename "$hs_dir") is $(session_how "$hs_state" "$hs_secs")"
    [ "$hs_item" = - ] || [ "$hs_dir" = "$main" ] || hs_msg="$hs_msg; it holds $hs_item, so the comments job skips that PR while it runs"
    hs_msg="$hs_msg. End it if nobody uses it: kill $hs_pid"
    health_say pool "stale session: $hs_msg"
    health_notify "Stale session: $hs_msg"
  done < "$home/health/.sessions.$$"
  rm -f "$home/health/.sessions.$$"
  [ "$dry" -eq 1 ] && return 0
  for hs_f in "$home"/health/stale-session-*.seen; do
    [ -f "$hs_f" ] || continue
    hs_k="$(basename "$hs_f" .seen)"
    case " $hs_keys " in *" $hs_k "*) ;; *) rm -f "$hs_f" ;; esac
  done
}

# cmd_sessions [--stale]: the sessions table, stale ones first, each stale one with its kill command.
cmd_sessions() {
  only=0
  while [ $# -gt 0 ]; do case "$1" in --stale) only=1; shift ;; *) die "unknown option $1" 2 ;; esac; done
  stale_session="$(hpy seconds jobs.health.stale_session "$(cfg_or jobs.health.stale_session 24h)")" || exit 2
  run_procs
  session_rows "$procs" "$stale_session" > "$home/health/.sessions.$$"; run_procs_done
  printf '%-7s %-7s %-8s %-24s %-10s %-16s %s\n' pid host kind worktree item state ''
  sort -t "$(printf '\t')" -k7,7r -k6,6nr "$home/health/.sessions.$$" | while IFS="$(printf '\t')" read -r cs_pid cs_host cs_kind cs_dir cs_state cs_secs cs_stale cs_item; do
    [ "$only" -eq 0 ] || [ "$cs_stale" = 1 ] || continue
    cs_end=""; [ "$cs_stale" = 1 ] && cs_end="STALE: kill $cs_pid"
    printf '%-7s %-7s %-8s %-24s %-10s %-16s %s\n' "$cs_pid" "$cs_host" "$cs_kind" "$(basename "$cs_dir")" "$cs_item" "$(session_how "$cs_state" "$cs_secs")" "$cs_end"
  done
  rm -f "$home/health/.sessions.$$"
}

health_settings() {
  . "$FLOW_PLUGIN/lib/host.sh"
  grace="$(hpy seconds jobs.health.grace "$(cfg_or jobs.health.grace 10m)")" || exit 2
  reminder="$(hpy seconds jobs.health.gate_reminder "$(cfg_or jobs.health.gate_reminder 24h)")" || exit 2
  stale_session="$(hpy seconds jobs.health.stale_session "$(cfg_or jobs.health.stale_session 24h)")" || exit 2
  max_resumes="$(cfg_or jobs.health.max_resumes 3)"; behind_base="$(cfg_or jobs.health.behind_base 20)"; push="$(cfg_or jobs.health.push false)"
  case "$max_resumes$behind_base" in *[!0-9]*) die "jobs.health.max_resumes and jobs.health.behind_base take whole numbers" 2 ;; esac
}

# resume_pair_check: an --effort the resume host does not take exits 2 before anything changes.
resume_pair_check() {
  case "$resume_host" in claude|codex) _bad="$(host_effort_problem "$resume_host" "$resume_effort" --effort)"; [ -z "$_bad" ] || die "$_bad" 2 ;; esac
}

cmd_health() {
  dry=0; wait_for_resume=0; resume_host="$(cfg_or jobs.host claude)"; resume_model=""; resume_effort=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1; shift ;; --wait) wait_for_resume=1; shift ;; --host) resume_host="$2"; shift 2 ;;
      --model) [ $# -ge 2 ] || die "--model takes a model name" 2; resume_model="$2"; shift 2 ;;
      --effort) [ $# -ge 2 ] || die "--effort takes a level" 2; resume_effort="$2"; shift 2 ;;
      *) die "unknown option $1" 2 ;;
    esac
  done
  health_settings
  resume_pair_check
  health_trackers="$(adapters_configured)" || exit 2
  FLOW_LOCK_WAIT="${FLOW_LOCK_WAIT:-10}"
  now="$(date +%s)"; facts=0; claims=0; running=0; gated=0; reviewing=0; waiting=0; claimable=0; released=0; holders=""
  health_in_review=""; health_records=""
  mkdir -p "$home/health" "$home/log"
  procs="${FLOW_HEALTH_PROCS:-}"; procs_ok=1
  if [ -z "$procs" ]; then
    find "$home/health" -name '.procs.*' -mmin +60 -exec rm -f {} + 2>/dev/null
    procs="$home/health/.procs.$$"
    if ! hpy procs > "$procs" 2>/dev/null; then
      rm -f "$procs"
      procs_ok=0
      health_changed procs failed && health_say pool "cannot list processes (ps failed or listed nothing), so no run is judged dead; claimed worktrees are left as they are"
    else health_cleared procs; fi
  fi
  have_remote=0
  if git -C "$main" remote get-url origin >/dev/null 2>&1; then
    if [ "$dry" -eq 1 ] || git -C "$main" fetch -q --prune origin >/dev/null 2>&1; then have_remote=1; health_cleared fetch
    else health_changed fetch failed && health_say pool "git fetch origin failed; branches are not synced this run"; fi
  fi
  for p in $(pool_paths); do
    if [ ! -d "$p" ]; then health_missing "$p"; claimable=$((claimable + 1)); continue; fi
    health_cleared "missing-$(basename "$p")"
    reserver="$(reserved_by "$p")"
    if [ -n "$reserver" ]; then
      claims=$((claims + 1)); holders="$holders$(basename "$p") (reserved) $reserver works in it by hand
"
    elif [ -z "$(json_get "$(claim_of "$p")" item)" ]; then
      health_free "$p"
      dirty "$p" || claimable=$((claimable + 1))
    else health_claim "$p"; fi
  done
  # A review record of a PR no longer at the merge gate is stale: the console would trust it.
  if [ "$dry" -eq 0 ]; then
    for hv_f in "$home"/reviews/*.review.json; do
      [ -f "$hv_f" ] || continue
      case " $health_records " in *" $(basename "$hv_f") "*) ;; *) rm -f "$hv_f" ;; esac
    done
  fi
  health_gates
  health_list
  health_splits
  health_holds
  rm -f "$health_items"
  health_pressure
  health_next_runs
  [ "$procs_ok" -eq 0 ] || health_sessions
  [ "${FLOW_HEALTH_PROCS:-}" = "$procs" ] || rm -f "$procs"
  echo "health: $claims claimed ($running running, $gated at a gate$([ "$reviewing" -eq 0 ] || echo ", $reviewing in review")), $claimable free, $waiting gate(s) waiting; $([ "$facts" -eq 0 ] && echo "nothing to do" || echo "$facts finding(s)")"
}

# --- stop and resume: the owner's hand on one item's run.
# item_id <id>: an item's id, gh#<n>, local:<kind>/<n>, or an id another adapter's prefix starts
# in the id characters (adapters/README.md); anything else exits 2.
item_id() {
  case "$1" in
    gh#|gh#*[!0-9]*) ;;
    gh#*) return 0 ;;
    local:epic/*|local:task/*|local:bug/*) case "${1#local:*/}" in ''|*[!0-9]*) ;; *) return 0 ;; esac ;;
    local:*|*[!A-Za-z0-9:#/_.-]*) ;;
    *) adapter_for "$1" >/dev/null && return 0 ;;
  esac
  die "not an item id: $1 (use gh#<n> or local:<kind>/<n>)" 2
}
descendants() { for c in $(pgrep -P "$1" 2>/dev/null); do echo "$c"; descendants "$c"; done; }
# run_procs: $procs, the process list the health job reads: FLOW_HEALTH_PROCS, else a fresh one
# that run_procs_done removes. When ps lists nothing it exits 1: no run is judged on a blank list.
run_procs() {
  procs="${FLOW_HEALTH_PROCS:-}"
  [ -z "$procs" ] || return 0
  mkdir -p "$home/health"; procs="$home/health/.procs.$$"
  hpy procs > "$procs" 2>/dev/null || { rm -f "$procs"; die "cannot list processes (ps failed or listed nothing), so the run is left as it is" 1; }
}
run_procs_done() { [ "${FLOW_HEALTH_PROCS:-}" = "$procs" ] || rm -f "$procs"; }
# run_of <item>: the run record's fields: rn_rec, rn_step, rn_pid, rn_path (the record's worktree,
# else the claim's). Returns 1 when the item has no record.
run_of() {
  rn_rec="$home/runs/$(item_slug "$1").json"
  [ -f "$rn_rec" ] || return 1
  rn_run="$(cat "$rn_rec")"; rn_step="$(json_get "$rn_run" step)"; rn_pid="$(json_get "$rn_run" pid)"
  rn_path="$(json_get "$rn_run" worktree)"; [ -n "$rn_path" ] || rn_path="$(cmd_find "$1")"
}

# cmd_stop <item>: end the item's run: the process its record names, when it still runs the
# unattended loop or a host session (the health job's test), and every process under it, as
# jobs.sh stop ends a job's. The record goes, so the health job does not resume the run; the claim,
# the worktree and its commits and changes stay, and the next job may continue the item. One
# events.log line and the item's last_event say it. Nothing in flight is said, exit 0.
cmd_stop() {
  item_id "$1"
  run_of "$1" || { echo "$1: no run in flight, nothing to stop"; return 0; }
  run_procs
  st_live="$(hpy alive "$procs" "$1" "${rn_path:-$home}" "$rn_pid")"; run_procs_done
  st_pids=""
  [ -z "$rn_pid" ] || [ "$st_live" != "pid $rn_pid" ] || st_pids="$(echo "$rn_pid"; descendants "$rn_pid")"
  # shellcheck disable=SC2086
  [ -z "$st_pids" ] || kill -TERM $st_pids 2>/dev/null
  rm -f "$rn_rec"
  st_said="run of ${rn_step:-?} stopped by the owner"
  printf '%s\t%s\tstopped\t%s\n' "$(now_iso)" "$1" "$st_said" >> "$home/events.log"
  write_state "$1" "last_event=$(now_iso) $st_said"
  if [ -n "$st_pids" ]; then
    echo "$1: $st_said: $(printf '%s\n' $st_pids | sort -u | wc -l | tr -d ' ') process(es) ended; the claim and the worktree are kept as they are"
  else
    echo "$1: $st_said: no process of it was running${st_live:+ (another one works in its worktree: $st_live, left alone)}; the record is cleared, so the health job does not resume it"
  fi
}

# cmd_resume <item> [--host H] [--wait] [--model M] [--effort E]: start again a run whose process is gone, as the health job
# resumes a dead run (health_resume): its record cleared, the same resume.md note in the step's
# brief, the same jobs.health.max_resumes count, then the escalation gate (exit 4). The run starts
# in the background on --host (default jobs.host), or in the foreground with --wait. A run still
# alive (the health job's test, without its grace) and an item with no record are refused, exit 1.
cmd_resume() {
  item_id "$1"; rs_item="$1"; shift
  dry=0; wait_for_resume=0; resume_host="$(cfg_or jobs.host claude)"; resume_model=""; resume_effort=""; facts=0; health_gate=""; health_kind=resume
  while [ $# -gt 0 ]; do
    case "$1" in
      --wait) wait_for_resume=1; shift ;; --host) [ $# -ge 2 ] || die "--host takes claude or codex" 2; resume_host="$2"; shift 2 ;;
      --model) [ $# -ge 2 ] || die "--model takes a model name" 2; resume_model="$2"; shift 2 ;;
      --effort) [ $# -ge 2 ] || die "--effort takes a level" 2; resume_effort="$2"; shift 2 ;;
      *) die "unknown option $1" 2 ;;
    esac
  done
  health_settings
  resume_pair_check
  run_of "$rs_item" || die "$rs_item has no run record, so there is no run to resume: the next job continues it from its step" 1
  [ -n "$rn_path" ] && [ -d "$rn_path" ] || die "$rs_item: the worktree of its run is gone, so the run cannot resume" 1
  run_procs
  rs_live="$(hpy alive "$procs" "$rs_item" "$rn_path" "$rn_pid")"; run_procs_done
  [ -z "$rs_live" ] || die "$rs_item: the run of ${rn_step:-?} is still alive ($rs_live): end it first with steward.sh stop $rs_item" 1
  host_check "$resume_host" || exit 2
  # The step health counts resumes by is the item's own (a sync run's record says sync).
  rs_step="$(state_get "$(adapter read "$rs_item" 2>/dev/null)" step)"; [ -n "$rs_step" ] || rs_step="$rn_step"
  mkdir -p "$home/health" "$home/log"
  health_reports="$rn_path/.flow/reports/$(item_slug "$rs_item")"
  rm -f "$rn_rec"
  write_state "$rs_item" "last_event=$(now_iso) owner: cleared the dead run of ${rs_step:-?} to resume it"
  health_say "$rs_item" "dead run of ${rs_step:-?} cleared by the owner"
  health_resume "$rs_item" "$rs_step" "$rn_path"
  [ -z "$health_gate" ] || exit 4
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  pool) cmd_pool ;;
  claim) [ $# -ge 1 ] || die "usage: claim <item> [--base <branch>]" 2; cmd_claim "$@" ;;
  find) [ $# -ge 1 ] || die "usage: find <item>" 2; cmd_find "$1" ;;
  reserve) cmd_reserve "$@" ;;
  release) [ $# -ge 1 ] || die "usage: release <item|path> [--force]" 2; cmd_release "$@" ;;
  tmp) cmd_tmp "$@" ;;
  add) cmd_add "${1:-}" ;;
  setup) [ $# -ge 1 ] || die "usage: setup <path|item>" 2; cmd_setup "$1" ;;
  prune) cmd_prune "$@" ;;
  sweep) cmd_sweep "$@" ;;
  split) [ $# -ge 1 ] || die "usage: split <item>" 2; cmd_split "$1" ;;
  keep-whole) [ $# -ge 1 ] || die "usage: keep-whole <item>" 2; cmd_keep_whole "$1" ;;
  kept-whole) [ $# -ge 1 ] || die "usage: kept-whole <item>" 2; kept_whole "$1" ;;
  health) cmd_health "$@" ;;
  sessions) cmd_sessions "$@" ;;
  stop) [ $# -ge 1 ] || die "usage: stop <item>" 2; cmd_stop "$1" ;;
  resume) [ $# -ge 1 ] || die "usage: resume <item> [--host H] [--wait] [--model M] [--effort E]" 2; cmd_resume "$@" ;;
  reports) [ $# -ge 1 ] || die "usage: reports <item>" 2; cmd_reports "$1" ;;
  *) sed -n '2,48p' "$0"; exit 2 ;;
esac
