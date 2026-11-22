bump: patch

- Verify runs every build, test and gate command that has paths when its comparison base cannot
  be resolved, instead of skipping them, and `{verify_base}` is then `unavailable`. The log
  and the report say the base was unavailable.
