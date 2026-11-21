bump: minor

- The flow makes an epic's branch itself. When the owner approves an epic's split (clears its
  decomposition gate with an answer or an option), the epic gets `epic/<n>`, pushed to the remote
  at the base the epic itself would start from: an epic branch above it, a `base:` line in its
  body, else the config base. In a repository with no remote it is a local branch. A branch that
  exists is left where it is, and a split sent back makes none.
- The health job gives the branch to an open epic that lacks one, has an open child and an
  approved split: an epic approved before this version, or one whose children the owner made by
  hand. An epic that waits at its decomposition gate, or whose steps have not reached it, gets
  none. `--dry-run` says what it would make.
- A branch that cannot be made (the remote refused the push, the epic's own base does not resolve)
  leaves the gate cleared, is said with why, and the children wait until it exists.
