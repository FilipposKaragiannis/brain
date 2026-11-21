bump: minor

- An epic's child no longer starts from the config base when its epic has no epic branch. While no
  epic above it has an `epic/<n>` branch on the remote, the item is not ready, a pick says which
  branch to push, and a named run or a worktree claim is refused (exit 4) with the epic and the
  branch in the item's `last_event`. It starts once the branch is pushed. A `base: <branch>` line
  in the item starts it elsewhere, a child of a parent that holds a claim still starts from that
  parent's task branch, and an item that already holds a claim keeps its base. Before, such a
  child was cut from the config base and its PR merged there, one slice of the epic at a time.
