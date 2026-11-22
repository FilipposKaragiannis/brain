bump: minor

- Build and test commands can use `{verify_base}` to select checks against the same commit as
  verify. A cached pass belongs to that comparison.
- The verify log receives a check's output while the check runs, so a run stopped at its limit
  shows where it stood.
- Verify runs every build, test and gate command that has paths when its comparison base cannot
  be resolved, instead of skipping them, and `{verify_base}` is then `unavailable`, which is no
  commit id. The log and the report say the base was unavailable.
