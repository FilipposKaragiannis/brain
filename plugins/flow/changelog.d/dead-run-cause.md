bump: patch

- The escalation gate for a run that kept dying says what the runs left. The health job's gate
  said only that the run of a step died `jobs.health.max_resumes` times in a row and pointed at the
  log folder, so the owner had to read the logs before answering. It now says whether the last
  session wrote the step's result after the last resume with nothing left to read it (the loop
  was ended from outside, and the step's own work may be done), quotes the run's last log lines or
  says that it logged none (a killed loop, not a failed session), and names the one log to read,
  `log/resume-<item>.log`.
- The flow suite no longer kills the run that runs it. Its fake host, which stands in for a
  session that dies with its loop, walked up every ancestor and killed each one named
  `run-unattended.sh`. `steward.sh health --wait` runs the loop in the foreground, so the walk
  reached the real loop of the implement, test or verify step that ran the suite and killed it
  too: in this repository every such step on a flow item died once per suite run, and three in a
  row raised the escalation gate. The walk now stops at the suite.
