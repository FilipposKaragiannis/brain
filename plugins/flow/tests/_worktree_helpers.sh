# _worktree_helpers.sh: commit_in, one commit in a worktree, and hold, an item claimed by next with its
# worktree. Takes $P. Sourced after _flow_setup.sh, never run.
commit_in() { printf '%s\n' "$2" > "$1/$2.txt" && git -C "$1" add -- "$2.txt" && git -C "$1" commit -qm "$2" && git -C "$1" rev-parse HEAD; }
hold() { "$P/scripts/next.sh" "$1" >/dev/null && "$P/scripts/steward.sh" find "$1"; }
