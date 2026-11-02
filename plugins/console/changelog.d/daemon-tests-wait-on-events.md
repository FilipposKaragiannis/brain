bump: patch

- The daemon's action tests wait for the event they need, not a fixed 10 ms: an action's end as
  the runner announces it, the monitor reads the runner asked for, and the config writer being
  called. Under load the hand-off's second jobs read and the sync hand-off's failed note no longer
  fail the suite.
