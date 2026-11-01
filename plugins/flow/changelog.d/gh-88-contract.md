bump: minor

- A tracker is a plug-in point with a written contract: `adapters/README.md` gives every script,
  its arguments, output and exit codes, the item JSON and the state keys, the `<adapter>.*` config
  and the readiness keys, how each adapter keeps the flow state, and what a test fake must do.
  `tests/adapter-contract.sh <adapter>` checks an adapter against it with its fake backend;
  `tests/run.sh` runs it for `github` and `local`.
- An adapter owns its ids through its folder: `prefix` holds the id prefix and `slug.sed` turns a
  slug back into an id. `lib/flow.sh` (`adapter_for`, the new `slug_item`), the ready filter, the
  worktree hook, the steward and the comments job read them, so a third adapter needs no edit
  there.
- The adapters agree where they differed: an id the adapter does not own, an unknown option or an
  unknown state key exits 2 on both; GitHub's `write-state` refuses a key outside the fourteen
  state keys instead of storing it; `local create` takes `--type` (left out, said on stderr), which
  `flow:new` passes on, instead of failing on it.
