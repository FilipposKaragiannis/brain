bump: patch

- The demo stops the runs and fake agents it started where ps cannot run, as in a sandbox that
  refuses the setuid /bin/ps on macOS, instead of leaving them going after the demo is gone.
