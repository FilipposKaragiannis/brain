bump: patch

- The settings page has a Longest pass field under the Comments job (`jobs.comments.pass_limit`):
  how long one comments pass may run before it is stopped and counted as failed. Unset, 1h. The
  help of PRs addressed at once (`jobs.comments_workers`) now says it caps the passes across all
  runs. Needs flow with the comments pass limit.
