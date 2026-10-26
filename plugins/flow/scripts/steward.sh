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
#   steward.sh split <item>                      a task split into tracker tasks waits on its
#                                                children: step split, its worktree released
#                                                (kept when dirty), its branch kept when it holds
#                                                commits past the base
#   steward.sh keep-whole <item>                 the owner kept it whole: no split until its plan
#                                                step rewrites plan.md (kept-whole <item> asks)
#   steward.sh health [--dry-run] [--host H] [--wait]
#                                                check every claim: clear a dead run, release an
#                                                empty claim, finish a split, resume cut-off work,
#                                                sync branches, remind on old gates, say when the
#                                                pool is stuck
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
  # The branch goes only when the base holds every commit of it: git branch -d alone would also
  # delete one that is merged into its upstream but ahead of the base.
  if [ -n "$branch" ] && git -C "$p" show-ref --verify --quiet "refs/heads/$branch"; then
    if [ "$force" -eq 1 ]; then git -C "$p" branch -q -D "$branch"
    elif ! git -C "$p" merge-base --is-ancestor "refs/heads/$branch" "$(base_ref "$base")" 2>/dev/null ||
         ! git -C "$p" branch -q -d "$branch" 2>/dev/null; then echo "flow: $branch is not merged into $(base_ref "$base"); kept. Use --force to delete it." >&2; fi
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

# --- health: the pool checked in order, claim by claim. See jobs/health.sh, which runs it.
hpy() { python3 -I "$FLOW_PLUGIN/scripts/_health.py" "$@"; }

# health_say <item> <fact>: one line per fact, on stdout and in events.log.
health_say() {
  echo "$1: $2"
  facts=$((facts + 1))
  [ "$dry" -eq 1 ] && return 0
  printf '%s\t%s\thealth\t%s\n' "$(now_iso)" "$([ "$1" = pool ] && echo - || echo "$1")" "$2" >> "$home/events.log"
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

# health_free <path>: a free pool worktree follows the base branch tip; a dirty one is only said.
health_free() {
  hf_name="$(basename "$1")"
  if dirty "$1"; then
    health_changed "free-$hf_name" dirty && health_say pool "$hf_name is free but has uncommitted changes, so no claim can use it"
    return 0
  fi
  health_cleared "free-$hf_name"
  hf_tip="$(git -C "$1" rev-parse -q --verify "$(base_ref)" 2>/dev/null)"; hf_head="$(git -C "$1" rev-parse -q --verify HEAD 2>/dev/null)"
  [ -n "$hf_tip" ] && [ "$hf_tip" != "$hf_head" ] || return 0
  if git -C "$1" symbolic-ref -q HEAD >/dev/null 2>&1; then
    health_changed "free-$hf_name-branch" on && health_say pool "$hf_name is free but on the branch $(git -C "$1" symbolic-ref --short HEAD), so it is not moved"
  elif ! git -C "$1" merge-base --is-ancestor "$hf_head" "$hf_tip" 2>/dev/null; then
    health_changed "free-$hf_name-branch" off && health_say pool "$hf_name is free but its commit is not in $base_branch, so it is not moved"
  elif [ "$dry" -eq 1 ]; then health_say pool "would fast-forward free $hf_name to $base_branch"
  elif git -C "$1" merge -q --ff-only "$hf_tip" >/dev/null 2>&1; then health_say pool "fast-forwarded free $hf_name to $base_branch"
  else health_say pool "could not fast-forward free $hf_name"; fi
}

# health_resume <item> <step> <path>: start the step again in the background, where the dead run
# left it, at most max_resumes times in a row while the step does not advance; then escalate. The
# note for the resumed step goes in resume.md, which next.sh puts in that one brief and removes.
health_resume() {
  hr_item="$1"; hr_step="$2"; hr_path="$3"; hr_file="$home/health/$(item_slug "$1").resume"
  hr_n=0; hr_last=""
  [ -f "$hr_file" ] && read -r hr_n hr_last < "$hr_file"
  [ "$hr_last" = "$hr_step" ] || hr_n=0
  if [ "$hr_n" -ge "$max_resumes" ]; then
    if [ "$dry" -eq 1 ]; then health_say "$hr_item" "would raise an escalation gate: the run of $hr_step died $hr_n times in a row"; return 0; fi
    health_say "$hr_item" "the run of $hr_step died $hr_n times in a row without the step advancing; escalation gate raised"
    "$FLOW_PLUGIN/scripts/gate.sh" raise "$hr_item" escalation "The run of step $hr_step died $hr_n times in a row, and the health job resumed it each time without the step advancing. $(basename "$hr_path") keeps its commits and uncommitted changes untouched. Read $home/log, then clear the gate to let the flow try again." >/dev/null 2>&1 || true
    rm -f "$hr_file"; health_gate=escalation
    return 0
  fi
  if [ "$dry" -eq 1 ]; then health_say "$hr_item" "would resume $hr_step on $resume_host (attempt $((hr_n + 1)) of $max_resumes)"; return 0; fi
  if ! host_check "$resume_host" >/dev/null 2>&1; then health_say "$hr_item" "cannot resume $hr_step: $resume_host is not installed"; return 0; fi
  hr_n=$((hr_n + 1)); printf '%s %s\n' "$hr_n" "$hr_step" > "$hr_file"
  mkdir -p "$health_reports" && printf 'The previous run of step %s died. Health job resume %s of %s: this worktree holds its commits and uncommitted changes. Read git status and git log, continue from there, and discard nothing.\n' "$hr_step" "$hr_n" "$max_resumes" > "$health_reports/resume.md"
  health_say "$hr_item" "resumed $hr_step on $resume_host (attempt $hr_n of $max_resumes)"
  hr_run="$FLOW_PLUGIN/templates/run-unattended.sh"; hr_log="$home/log/resume-$(item_slug "$hr_item").log"
  if [ "$wait_for_resume" -eq 1 ]; then "$hr_run" "$resume_host" "$hr_item" >> "$hr_log" 2>&1
  else hpy spawn "$hr_log" "$hr_run" "$resume_host" "$hr_item" >/dev/null; fi
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
  [ -z "$health_gate" ] || { gated=$((gated + 1)); holders="$holders$name $it waiting at the $health_gate gate
"; }
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
  hs_rows="$(for a in $(adapters_configured); do adapter list "$a" 2>/dev/null; echo; done | python3 -I -c '
import json, sys
for line in sys.stdin:
    if line.strip():
        for i in json.loads(line):
            s = i.get("state") or {}
            if s.get("step") == "split" and not i.get("open_children"): print("split=" + i["id"])
            elif s.get("step") == "done" and s.get("gate", "none") in ("", "none"): print("done=" + i["id"])')"
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
  hpy next-streaks "$home/log" > "$home/health/.next-streaks"
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
  done < "$home/health/.next-streaks"
  rm -f "$home/health/.next-streaks"
  for hn_f in "$home"/health/next-lock-*.seen "$home"/health/next-nostep-*.seen; do
    [ -f "$hn_f" ] || continue
    case " $hn_keys " in *" $(basename "$hn_f" .seen) "*) ;; *) health_cleared "$(basename "$hn_f" .seen)" ;; esac
  done
}

cmd_health() {
  dry=0; wait_for_resume=0; resume_host="$(cfg_or jobs.host claude)"
  while [ $# -gt 0 ]; do
    case "$1" in --dry-run) dry=1; shift ;; --wait) wait_for_resume=1; shift ;; --host) resume_host="$2"; shift 2 ;; *) die "unknown option $1" 2 ;; esac
  done
  . "$FLOW_PLUGIN/lib/host.sh"
  grace="$(hpy seconds jobs.health.grace "$(cfg_or jobs.health.grace 10m)")" || exit 2
  reminder="$(hpy seconds jobs.health.gate_reminder "$(cfg_or jobs.health.gate_reminder 24h)")" || exit 2
  max_resumes="$(cfg_or jobs.health.max_resumes 3)"; behind_base="$(cfg_or jobs.health.behind_base 20)"; push="$(cfg_or jobs.health.push false)"
  case "$max_resumes$behind_base" in *[!0-9]*) die "jobs.health.max_resumes and jobs.health.behind_base take whole numbers" 2 ;; esac
  FLOW_LOCK_WAIT="${FLOW_LOCK_WAIT:-10}"
  now="$(date +%s)"; facts=0; claims=0; running=0; gated=0; waiting=0; claimable=0; released=0; holders=""
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
    [ -d "$p" ] || continue
    if [ -z "$(json_get "$(claim_of "$p")" item)" ]; then
      health_free "$p"
      dirty "$p" || claimable=$((claimable + 1))
    else health_claim "$p"; fi
  done
  health_gates
  health_splits
  health_pressure
  health_next_runs
  [ "${FLOW_HEALTH_PROCS:-}" = "$procs" ] || rm -f "$procs"
  echo "health: $claims claimed ($running running, $gated at a gate), $claimable free, $waiting gate(s) waiting; $([ "$facts" -eq 0 ] && echo "nothing to do" || echo "$facts finding(s)")"
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
  split) [ $# -ge 1 ] || die "usage: split <item>" 2; cmd_split "$1" ;;
  keep-whole) [ $# -ge 1 ] || die "usage: keep-whole <item>" 2; cmd_keep_whole "$1" ;;
  kept-whole) [ $# -ge 1 ] || die "usage: kept-whole <item>" 2; kept_whole "$1" ;;
  health) cmd_health "$@" ;;
  reports) [ $# -ge 1 ] || die "usage: reports <item>" 2; cmd_reports "$1" ;;
  *) sed -n '2,28p' "$0"; exit 2 ;;
esac
