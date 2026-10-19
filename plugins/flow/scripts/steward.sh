#!/bin/sh
# Worktree steward: the pool, claims, releases and temporary worktrees.
#   steward.sh pool                              list the pool with claim, branch and dirt
#   steward.sh claim <item> [--base <branch>]    claim a free pool worktree, print its path
#   steward.sh find <item>                       print the claimed path, or nothing
#   steward.sh release <item|path> [--force]     reset to the base, delete the task branch, clear
#                                                the claim; a closed item's reports go too
#   steward.sh reports <item>                    print (and create) the item's reports folder
#   steward.sh tmp add <item> <phase>            temporary worktree from the task branch
#   steward.sh tmp remove <path>                 remove it and its branch
#   steward.sh add [path]                        add a worktree to the pool (git worktree add,
#                                                pool entry in config.yaml, copies and setup)
#   steward.sh setup <path>                      run worktree_copy and worktree_setup there
#   steward.sh prune [--dry-run]                 delete the reports of closed items, in the main
#                                                worktree and every pool worktree
#   steward.sh sweep [--dry-run]                 release each worktree whose work landed: its item
#                                                is closed, or its PR is merged
# A claim with no free worktree adds one while the pool is below pool_max (config.yaml), named
# after the last pool entry (../app-wt-3 after ../app-wt-2). worktree_copy lists ignored paths
# copied from the main worktree when the new one lacks them (.claude/settings.local.json);
# worktree_setup lists commands run in the new worktree. Both run on add and on setup.
# Never resets a worktree with uncommitted changes: release exits 3 and says so (escalate).
. "$(dirname "$0")/../lib/flow.sh"

home="$(flow_home)"
main="$(dirname "$home")"
base_branch="$(cfg_or base main)"

pool_paths() {
  cfg pool | while read -r p; do
    [ -n "$p" ] || continue
    case "$p" in /*) printf '%s\n' "$p" ;; *) printf '%s\n' "$(cd "$main" && cd "$p" 2>/dev/null && pwd || printf '%s/%s' "$main" "$p")" ;; esac
  done
}

base_ref() {
  b="${1:-$base_branch}"
  if git -C "$main" show-ref --verify --quiet "refs/remotes/origin/$b"; then printf 'origin/%s' "$b"; else printf '%s' "$b"; fi
}

claim_of() { [ -f "$1/.flow/claim.json" ] && cat "$1/.flow/claim.json"; }

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
  free=""
  for p in $(pool_paths); do
    [ -d "$p" ] || continue
    [ -z "$(json_get "$(claim_of "$p")" item)" ] || continue
    dirty "$p" && continue
    free="$p"; break
  done
  [ -n "$free" ] || free="$(grow_pool)" || die "no free worktree in the pool (every pool entry is claimed, dirty or missing) and the pool is at pool_max ($(cfg_or pool_max 0)). Release one, or raise pool_max in $(config_file)." 3
  slug="$(item_slug "$item")"; branch="flow/$slug"
  git -C "$main" remote get-url origin >/dev/null 2>&1 && git -C "$main" fetch -q origin "$base" 2>/dev/null
  ref="$(base_ref "$base")"
  if git -C "$free" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$free" switch -q "$branch" || die "cannot switch $free to $branch"
  else
    git -C "$free" switch -q -c "$branch" "$ref" || die "cannot create $branch from $ref in $free"
  fi
  mkdir -p "$free/.flow"
  json_obj "item=$item" "worktree=$free" "name=$(basename "$free")" "branch=$branch" "base=$base" "step=" \
    "claimed_at=$(now_iso)" "host=$(host_name)" > "$free/.flow/claim.json"
  write_state "$item" "worktree=$(basename "$free")" "last_event=$(now_iso) claimed $(basename "$free")"
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
  git -C "$p" switch -q --detach "$(base_ref "$base")" || die "cannot detach $p at $(base_ref "$base")"
  if [ -n "$branch" ] && git -C "$p" show-ref --verify --quiet "refs/heads/$branch"; then
    if [ "$force" -eq 1 ]; then git -C "$p" branch -q -D "$branch"
    elif ! git -C "$p" branch -q -d "$branch" 2>/dev/null; then echo "flow: $branch is not merged; kept. Use --force to delete it." >&2; fi
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

# next_pool_path: the path a new pool worktree gets, following the last entry's name
# (../app-wt-2 -> ../app-wt-3) or ../<main>-wt-<n> when the pool is empty or named otherwise.
next_pool_path() {
  last="$(cfg pool | grep . | tail -1)"
  case "$last" in
    *-wt-[0-9]*) stem="${last%-wt-*}" ;;
    *) stem="../$(basename "$main")" ;;
  esac
  n=1
  while :; do
    cand="$stem-wt-$n"
    case "$cand" in /*) abs="$cand" ;; *) abs="$main/$cand" ;; esac
    cfg pool | grep -qx "$cand" || [ -e "$abs" ] || { printf '%s' "$cand"; return; }
    n=$((n + 1))
  done
}

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

# grow_pool: add one worktree when the pool is below pool_max; print its path.
grow_pool() {
  max="$(cfg_or pool_max 0)"
  count="$(cfg pool | grep -c .)"
  [ "$max" -gt "$count" ] 2>/dev/null || return 1
  rel="$(next_pool_path)"
  case "$rel" in /*) abs="$rel" ;; *) abs="$main/$rel" ;; esac
  git -C "$main" worktree add -q --detach "$abs" "$(base_ref)" || return 1
  pool_add_entry "$rel"
  run_setup "$abs" >&2
  echo "flow: added $rel to the pool ($((count + 1)) of $max)" >&2
  (cd "$abs" && pwd)
}

cmd_add() {
  rel="${1:-$(next_pool_path)}"
  case "$rel" in /*) abs="$rel" ;; *) abs="$main/$rel" ;; esac
  git -C "$main" worktree add -q --detach "$abs" "$(base_ref)" || die "cannot add worktree $rel"
  pool_add_entry "$rel"
  run_setup "$abs"
  echo "added $rel to the pool in $(config_file)."
}

cmd_setup() {
  p="$(resolve_path "$1")"; [ -n "$p" ] && [ -d "$p" ] || die "no worktree at $1" 2
  run_setup "$p"
}

# slug_item <reports folder name>: the item id item_slug made it from (gh-12 -> gh#12,
# local-task-3 -> local:task/3), or nothing for a folder no adapter owns.
slug_item() {
  printf '%s' "$1" | sed -n 's/^gh-\([0-9][0-9]*\)$/gh#\1/p; s/^local-\([a-z][a-z0-9]*\)-\([0-9][0-9]*\)$/local:\1\/\2/p'
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
cmd_sweep() {
  dry=0
  while [ $# -gt 0 ]; do case "$1" in --dry-run) dry=1; shift ;; *) die "unknown option $1" 2 ;; esac; done
  for p in $(pool_paths); do
    [ -d "$p" ] || continue
    c="$(claim_of "$p")"; it="$(json_get "$c" item)"; br="$(json_get "$c" branch)"; name="$(basename "$p")"
    [ -n "$it" ] && adapter_for "$it" >/dev/null 2>&1 || continue
    data="$(adapter read "$it" 2>/dev/null)" || continue
    status="$(json_get "$data" status)"; gate="$(state_get "$data" gate)"; pr="$(state_get "$data" pr)"
    merged=0; head=""
    if [ -n "$pr" ] && st="$("$FLOW_PLUGIN/scripts/comments.sh" state "$pr" 2>/dev/null)" && [ "$(json_get "$st" state)" = MERGED ]; then
      merged=1; head="$(json_get "$st" headRefOid)"
    fi
    [ "$status" = closed ] || [ "$merged" -eq 1 ] || continue
    why="$it is closed"; [ "$merged" -eq 1 ] && why="$pr merged"
    if [ -f "$home/runs/$(item_slug "$it").json" ]; then echo "$it: kept $name, a run is in flight"; continue; fi
    if dirty "$p"; then echo "$it: kept $name, it has uncommitted changes ($why)"; continue; fi
    if [ "$dry" -eq 1 ]; then echo "$it: would release $name ($why)"; continue; fi
    [ "$gate" = merge ] && "$FLOW_PLUGIN/scripts/gate.sh" clear "$it" "$(if [ "$merged" -eq 1 ]; then echo "merged: $pr"; else echo "closed"; fi)" >/dev/null
    [ "$status" = closed ] || adapter close "$it" --comment "Closed by flow: $pr is merged." >/dev/null || echo "flow: could not close $it" >&2
    force=""
    [ -n "$head" ] && [ "$(git -C "$p" rev-parse -q --verify "refs/heads/$br" 2>/dev/null)" = "$head" ] && force="--force"
    (cmd_release "$p" $force >/dev/null) && echo "$it: released $name ($why)"
  done
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  pool) cmd_pool ;;
  claim) [ $# -ge 1 ] || die "usage: claim <item> [--base <branch>]" 2; cmd_claim "$@" ;;
  find) [ $# -ge 1 ] || die "usage: find <item>" 2; cmd_find "$1" ;;
  release) [ $# -ge 1 ] || die "usage: release <item|path> [--force]" 2; cmd_release "$@" ;;
  tmp) cmd_tmp "$@" ;;
  add) cmd_add "${1:-}" ;;
  setup) [ $# -ge 1 ] || die "usage: setup <path|item>" 2; cmd_setup "$1" ;;
  prune) cmd_prune "$@" ;;
  sweep) cmd_sweep "$@" ;;
  reports) [ $# -ge 1 ] || die "usage: reports <item>" 2; cmd_reports "$1" ;;
  *) sed -n '2,18p' "$0"; exit 2 ;;
esac
