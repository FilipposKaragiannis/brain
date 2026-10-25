#!/bin/sh
# sync.sh <worktree> <base>: bring a claimed branch up to date, as worktree.sync runs it.
# Fetches origin, merges the branch's own upstream when it is ahead, then origin/<base> when it
# exists (else the local <base>). A merge that conflicts is aborted and the conflicting files are
# named, then the refs still to merge from that one on ("console: still to merge: <ref> ..."), so
# the console can hand them to the flow's sync step; the worktree is left as it was before that
# merge. Every merge is --no-edit, never forced. TERM or INT mid-merge aborts the merge too, and
# the script exits 143.
# sync.sh --refs <worktree> <base>: print the refs a sync would merge, one per line, without
# fetching or merging (sync.handoff writes them into the flow's sync note).
set -u
refs_only=0
if [ "${1:-}" = "--refs" ]; then refs_only=1; shift; fi
wt="$1"; base="$2"
say() { printf 'console: %s\n' "$*"; }
merging=""

# A timeout or a removed project sends TERM (to the whole group, so git stops too and drops its
# own lock files). A merge left half done is aborted, so the worktree never keeps a MERGE_HEAD.
stopped() {
  trap - TERM INT
  if git -C "$wt" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    git -C "$wt" merge --abort
    say "stopped while merging ${merging:-the base}; the merge was aborted"
  else
    say "stopped before a merge was under way"
  fi
  exit 143
}
trap stopped TERM INT

# merge <ref> [<later ref>...]: merge the first, or abort a conflicting merge and stop with the
# files and every ref still to merge.
merge() {
  merging="$1"
  if git -C "$wt" merge --no-edit "$1"; then say "merged $1"; merging=""; return 0; fi
  if git -C "$wt" rev-parse -q --verify MERGE_HEAD >/dev/null; then
    files="$(git -C "$wt" diff --name-only --diff-filter=U)"
    git -C "$wt" merge --abort
    say "merging $1 conflicts, so the merge was aborted. Conflicting files:"
    printf '%s\n' "$files"
    say "still to merge: $*"
  else
    say "git could not merge $1"
  fi
  exit 1
}

# pick_refs: the refs to merge, in order: the upstream when it has commits the branch lacks, then
# origin/<base> when it exists, else the local <base>.
pick_refs() {
  if [ -n "$upstream" ] && [ "$(git -C "$wt" rev-list --count "HEAD..$upstream")" -gt 0 ]; then printf '%s\n' "$upstream"; fi
  if git -C "$wt" rev-parse -q --verify "refs/remotes/origin/$base" >/dev/null; then printf '%s\n' "origin/$base"; else printf '%s\n' "$base"; fi
}

if [ "$refs_only" -eq 0 ]; then
  if git -C "$wt" remote get-url origin >/dev/null 2>&1; then
    git -C "$wt" fetch origin || { say "git fetch origin failed"; exit 1; }
  else
    say "no origin remote: merging the local $base"
  fi
fi

upstream="$(git -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
refs="$(pick_refs)"
if [ "$refs_only" -eq 1 ]; then printf '%s\n' "$refs"; exit 0; fi
[ -z "$upstream" ] || printf '%s\n' "$refs" | grep -qxF "$upstream" || say "$upstream has nothing the branch lacks"

# One ref per word: a branch name holds no space.
set -- $refs
while [ $# -gt 0 ]; do merge "$@"; shift; done
