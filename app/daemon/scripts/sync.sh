#!/bin/sh
# sync.sh <worktree> <base>: bring a claimed branch up to date, as worktree.sync runs it.
# Fetches origin, merges the branch's own upstream when it is ahead, then origin/<base> when it
# exists (else the local <base>). A merge that conflicts is aborted and the conflicting files are
# named; the worktree is left as it was before that merge. Every merge is --no-edit, never forced.
set -u
wt="$1"; base="$2"
say() { printf 'console: %s\n' "$*"; }

# merge <ref>: merge it, or abort a conflicting merge and stop with the files.
merge() {
  if git -C "$wt" merge --no-edit "$1"; then say "merged $1"; return 0; fi
  if git -C "$wt" rev-parse -q --verify MERGE_HEAD >/dev/null; then
    files="$(git -C "$wt" diff --name-only --diff-filter=U)"
    git -C "$wt" merge --abort
    say "merging $1 conflicts, so the merge was aborted. Conflicting files:"
    printf '%s\n' "$files"
  else
    say "git could not merge $1"
  fi
  exit 1
}

if git -C "$wt" remote get-url origin >/dev/null 2>&1; then
  git -C "$wt" fetch origin || { say "git fetch origin failed"; exit 1; }
else
  say "no origin remote: merging the local $base"
fi

upstream="$(git -C "$wt" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
if [ -n "$upstream" ] && [ "$(git -C "$wt" rev-list --count "HEAD..$upstream")" -gt 0 ]; then
  merge "$upstream"
elif [ -n "$upstream" ]; then
  say "$upstream has nothing the branch lacks"
fi

if git -C "$wt" rev-parse -q --verify "refs/remotes/origin/$base" >/dev/null; then target="origin/$base"; else target="$base"; fi
merge "$target"
