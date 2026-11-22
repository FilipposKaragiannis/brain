bump: patch

- Flow's python starts keep their compiled modules in `flow/python` under `XDG_CACHE_HOME`, or
  `~/.cache` when that is not an absolute path, made owner-only. On a Mac whose `python3` is
  Xcode's, a start no longer compiles the standard library and flow's helpers each time, which
  takes about a quarter off the holds and blockers suites. Python still runs isolated. A missing or
  unwritable cache folder, or a cache file python does not recognise, only costs time; a damaged
  compiled file that still reads as one fails the start, as in any `__pycache__`, until
  `flow/python` is removed. No `__pycache__` lands in the plugin.
