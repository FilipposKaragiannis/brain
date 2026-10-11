#!/bin/sh
# Worktree steward: the pool, claims, releases and temporary worktrees.
#   steward.sh pool                              list the pool with claim, branch and dirt
#   steward.sh claim <item> [--base <branch>]    claim a free pool worktree, print its path
#   steward.sh find <item>                       print the claimed path, or nothing
#   steward.sh release <item|path> [--force]     reset to the base, delete the task branch, clear
#   steward.sh tmp add <item> <phase>            temporary worktree from the task branch
#   steward.sh tmp remove <path>                 remove it and its branch
#   steward.sh add [path]                        add a worktree to the pool (git worktree add,
#                                                pool entry in config.yaml, copies and setup)
#   steward.sh setup <path>                      run worktree_copy and worktree_setup there
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

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  pool) cmd_pool ;;
  claim) [ $# -ge 1 ] || die "usage: claim <item> [--base <branch>]" 2; cmd_claim "$@" ;;
  find) [ $# -ge 1 ] || die "usage: find <item>" 2; cmd_find "$1" ;;
  release) [ $# -ge 1 ] || die "usage: release <item|path> [--force]" 2; cmd_release "$@" ;;
  tmp) cmd_tmp "$@" ;;
  add) cmd_add "${1:-}" ;;
  setup) [ $# -ge 1 ] || die "usage: setup <path|item>" 2; cmd_setup "$1" ;;
  *) sed -n '2,11p' "$0"; exit 2 ;;
esac
