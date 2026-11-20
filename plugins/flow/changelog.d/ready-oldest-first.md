bump: patch

- Among ready items of one rank the pick takes the lowest item number first, the oldest: a tracker
  numbers its items as they are made. Before, a tie kept the tracker's listing order, and GitHub
  and Jira list the newest first, so the newest item of a priority was picked first and an old one
  could wait behind every item filed after it.
