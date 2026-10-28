# flow

## 1.21.0 (2026-10-27)

- The board's graphs work with every adapter. `board.sh --graph <epic-id>` takes any item id
  (`gh#12`, `local:epic/3`) and builds the dependency model from the items each adapter lists:
  a child is an item whose parent is the id. Before, it took only `gh#N` and read GitHub's
  sub-issues itself, so a project on the local adapter got "--graph takes a GitHub epic id" and
  no graph. It also makes one list call per adapter instead of one GitHub call per child. Only
  direct children are nodes: a parent of epics shows its epics, not their children.
- A graph lets each adapter's errors through and stops when a list fails, so a failed `gh` call
  or a list cut at `github.limit` is said, never drawn as a smaller graph. A GitHub list fails
  when cut only with `FLOW_LIST_WHOLE` set, which a graph sets. The board itself still shows
  what it can.
- `board.sh --graph priorities` is new: every open item but epics, one column per priority,
  highest first by the tracker's order, an edge per open blocker. An edge where a lower
  priority item blocks a higher one is an inversion, listed in the model.
- `--mermaid` prints either graph as a Mermaid flowchart, so the board skill shows the script's
  drawing instead of writing one. Each item is filled by its priority, the same fill in both
  graphs. The epic's critical path, its nodes and its edges, has a thick red stroke. Titles are escaped, so a quote
  or a `#12;` cannot break a label.
- Blockers that form a cycle among an epic's children end the graph with a message naming them.
  Before, the layering looped forever.
- `scripts/epic_graph.py` is gone; `scripts/_graph.py` builds both graphs. In the epic model a
  node's closeout, enabler or behaviour is now `role`, not `kind`, since the priorities model
  uses `kind` for the item's kind.

## 1.20.8 (2026-10-27)

- The `health` job runs the sweep (`steward.sh sweep`) before its checks, as the `next` job
  does, so a merged PR clears its merge gate and frees its worktree within one health cycle.
  Before, only the `next` job swept, once at the start of a run.
- A `next` run with `--workers` starts the workers in their own session and ends; it no longer
  waits for them. launchd starts no run while the last is alive, so one long worker held every
  other worker and the sweep until it finished. On foosbrawl one 90-minute build kept three
  merged PRs at the merge gate and five idle workers off the queue. A busy worker is still
  skipped by its own lock. `--wait` keeps the old behaviour: stay until every worker ends and
  exit with the first failure.
- The sweep both jobs run is one helper, `job_sweep`. A held sweep lock and a failed sweep are
  now a line in the job log; before, both were silent. A worker that cannot start is a line in
  its own log.

## 1.20.7 (2026-10-26)

- A GitHub call that fails with a 5xx answer or a dropped connection is tried again, up to three
  tries, after 2 and then 5 seconds (`FLOW_GH_RETRY_WAIT`), and says so on stderr. The shell
  side is a `gh` function in `lib/flow.sh` that every flow script gets; the adapter's Python
  goes through `_call.py` with the same test and waits. A body the call reads from stdin is
  kept in a file first, so a second try sends it too, and only the last try's stdout reaches
  the caller (`gh api` prints the error body there). Any other failure is final at once. On
  foosbrawl, one `HTTP 502` while the run read the item after a step ended the run with exit 1
  and left the step's gate unapplied until the health job re-ran it 13 minutes later.
- A create is tried once: GitHub can take a write and lose the answer, and a second try would
  make a second one. `create.sh` makes its issue once; a reviewer ping is sent once (the chase
  covers a lost one); `write-state` posts the first state comment once and, when the answer is
  lost, looks for the comment, patches it when it landed, posts once more when it did not, and
  stops after that. A gate or PR comment and a review reply are still tried again, so a blip
  can repeat one of those; that is the cheaper mistake.
- A read whose comments call still fails after the tries ends with "cannot read the comments of
  gh#N" instead of answering an item with an empty state (no attempts, no PR, no touches); a
  list says so on stderr and leaves that issue out, so it is not picked, shown or synced that
  round, and goes on. `write-state` stops on any failed call instead of starting a second state
  comment from nothing, which dropped those fields; its callers in `advance.sh` and `next.sh`
  go on either way, as before. An empty answer no longer ends `read.sh` with a Python traceback.
- The state comment is looked for in every comment of the issue, not the first 100. The board's
  epic graph calls GitHub through the same retry.

## 1.20.6 (2026-10-26)

- `next.sh` reads the ready list before it takes the pick lock. Listing a tracker can take a
  minute (on foosbrawl, 66 seconds: the issues, then one read per blocker not in the list), and
  the lock wait is 60 seconds, so with two workers the second gave up every schedule with "a run
  is in flight" and only one item ran per half hour. The lock still covers what must not race:
  the run records, the claim and the item's state, all read under it.
- The ready filter judges an item that lists its open blockers (`open_blockers`, which the
  GitHub adapter fills from the same query) by that list, instead of reading every blocker
  through its adapter, one call apiece. On foosbrawl that is 83 blocker reads fewer per pick.
- The next job's last word for a worker that waited out the pick lock names that ("another
  worker held the pick for over 60s"), not "a run is in flight". The last word carries the
  steps the run made ("done, 3 steps"), and a pick that ended as if done without one step says
  "stopped: no step ran" with the reason from the log, so a stall is a word, not "done".
- The health job says once, and notifies, when a next worker's last two or more runs in a row all
  waited out the pick lock, or all ended without running a step. Both stalls of 1.20.5 and 1.20.6
  showed only as quiet runs in the history; now they are a finding, and `jobs status` counts a
  run that stopped without a step as failed, not as work.
- A line in `runs.jsonl` that is not a run record (not an object, or no job name) is skipped by
  `jobs status`, `jobs history` and the health job, instead of stopping them with a traceback.

## 1.20.5 (2026-10-26)

- The next job no longer stalls on an item that has nothing left to run. The ready list offered
  an open item whose every step ran (step `done`, no gate: its PR merged by hand, or its merge
  gate cleared without the sweep closing it) first by rank, and `next.sh` answered "is done
  (every step ran). Merge or close it." with exit 6 for every worker on every schedule, while the
  job logged "done" and the ready items behind it waited. On foosbrawl gh#239 held the queue from
  12:55 to 14:00 and gh#515 after it. Now the ready filter leaves out an item at step `done`, as
  it does a split one. A pick (no item named) that still reads an item with nothing to run, from
  a ready list older than the item's state, passes over it (closed, at a gate, done, or split),
  says why, and tries the next ready item; it exits 3 only when a claim found the pool full,
  else 5. Exit codes 4 and 6 are a named item's. The health job says once, and notifies, when an
  open item's every step ran and it waits at no gate: merge or close it; an item sent back to a
  step and done again is said again, and so is a split parent. The next job's last word for exit 6
  on a named item is the reason ("is done", "is closed", "every child is closed"), not "done".

## 1.20.4 (2026-10-25)

- The health job removes a sync note (`sync.md` in the item's reports) only once every ref it
  names is merged into the task branch. Before, it removed the note whenever its own check found
  nothing to sync (the branch has a PR, is close to its base, or waits at a gate), so a note
  another writer left, such as the Brain Console handing a conflicted merge to the flow, was gone
  within one cycle without a word. A note whose refs are all merged is removed and said once; one
  with a ref not merged yet is kept and nothing new is said; one with a ref that does not resolve
  is kept and said once, and the sync step escalates on it. When the health job writes its own
  refs, the note keeps the refs already there that are not merged yet. `--dry-run` still changes
  nothing.

## 1.20.3 (2026-10-25)

- The test writer splits a test whose assertions can fail independently before it commits, and
  never uses a call count on a double as a setup guard. Seven review blockers in twelve lessons
  were T-09 and T-08 on tests the writer had just committed. From the weekly retro, PR #40.

## 1.20.2 (2026-10-25)

- A plain `key=value` given to `json_obj` is always a JSON string. A value of digits only used to
  become a number, so a gate message, a tracker title, a lesson text, a job's last words or a pool
  folder of digits came back as a number, and one with a leading zero (`007`, a title `0451`, a
  folder `01`) wrote invalid JSON. The fields that are numbers on purpose say so with `key:=value`:
  `seconds` and `exit` in `runs.jsonl`, `pid` in the run record and `attempts` in
  `advance.sh --json`. A `pid` that is not a whole number is left out of the run record, and an
  `attempts` that is not one reads as 0, so neither can write invalid JSON. `depth` in
  `next.sh --json` is the review depth (`quick`, `standard`, `deep`, `none`) and stays a string.
  A `pid` or `attempts` with leading zeros is written without them (`0042` is 42, never octal).
- Records written before 1.20.2 with a digits value that has a leading zero are invalid JSON and
  are not rewritten; the readers (`jobs.sh`, `gate.sh list`, the health job, and now the board,
  which used to stop on one) skip them. A digits-only value from before 1.20.2 is a number:
  `jobs.sh status` and `history` read a `result` as text, and the board a gate `message`, instead
  of crashing.
- Without jq, `json_string` printed nothing for text that is not UTF-8, so `json_obj` wrote
  `{"d":,...}`; the python3 fallback now replaces such bytes with U+FFFD.
- The verify summary drops terminal hyperlinks (OSC 8, ended by BEL or ST, or cut short with no
  end) and keeps the link's text; before, the link target was left in the summary.
- `verify.sh` removes its temp files when it is stopped by INT or TERM: dash runs no EXIT trap on
  a signal, so each signal's trap removes them and then re-raises the signal, so the parent still
  sees verify killed by it.
- The flow tests that chained a second condition after `check` with `&&` (38 of them) or piped its
  output (one) tested only the first part; they now run whole inside `check_all`.

## 1.20.1 (2026-10-25)

- The verify report is never empty. `verify.sh` built `verify.json` by gluing JSON strings
  together in the shell, and a plain integer became a JSON number, so a short head sha of digits
  with a leading zero (`0123456`, about one commit in 270) made invalid JSON; the pretty-print
  failed and the redirect left an empty `verify.json` while verify still exited as if it had
  written one. A command output that was not UTF-8 did the same without jq.
- The checks are now recorded as NUL-delimited fields and the report is built from that data by
  `scripts/_verify_report.py`: every value is a string where the schema says so (`head` too),
  bytes that are not UTF-8 are replaced, and a summary is the last five non-empty lines on one
  line, without control characters or terminal colours, cut to 400 characters. `verify.json` and
  `verify.md` are written to a temp file and renamed into place, so a reader sees the old report
  or the new one, never an empty or half-written one.
- A report that cannot be built fails loudly: verify prints the cause on stderr, writes a
  minimal valid `verify.json` with status `fail` and the cause as a `report` check summary, and a
  `verify.md` saying so, and exits 1.

## 1.20.0 (2026-10-25)

- The jobs' model and effort are set per host. New keys in `.flow/config.yaml`:
  `jobs.claude.model`, `jobs.claude.effort`, `jobs.codex.model` and `jobs.codex.effort`. A job
  (comments, intake, retro) reads the pair of the host it runs on (`jobs.host`, default claude)
  and passes each value to that host as written: `--model` and `--effort` to `claude`, `-m` and
  `model_reasoning_effort` to `codex exec`, with no name mapping. Empty or missing is the host's
  own default: no flag is passed.
- `jobs.model` and `jobs.effort` are deprecated and read for this release only, when the job's
  host has no `jobs.<host>` map: the old mapping still applies for Codex (opus to gpt-6-sol,
  sonnet and haiku to gpt-6-luna, fable to gpt-6-astra), and the run logs one warning naming the
  new keys. Migrate by moving the values under `jobs.claude` (as they were) and `jobs.codex`
  (with Codex names).
- A bad value stops a job at its start with exit 2 and the line to fix: a `jobs.host` other
  than claude or codex stops every job; a Claude effort other than low, medium, high, xhigh or
  max, or a Codex effort other than low, medium, high or xhigh, stops only the jobs that read
  the pair (comments, intake, retro; `next` and `health` never do), and is recorded as a failed
  run in `runs.jsonl` and the job's log, so `jobs.sh status` shows it. `jobs.sh run` and
  `install` refuse the same values for the same jobs.
- `init` writes the new block, each key explained, in a fresh config. `init --check` reports a
  bad `jobs.host` or effort as a gap with its line, does not ask an existing project for the new
  keys, and says once that `jobs.model`/`jobs.effort` are deprecated when they are set.
- The unattended loop still passes the roster's names, mapped for Codex (`host_run` takes
  `as-is` as a sixth argument for the jobs).

## 1.19.0 (2026-10-25)

- A comments pass the host cut short is failed, not done. A non-zero exit, or Claude stopping
  the addresser at its background-task ceiling (a line near the end of the output that opens
  with "Background tasks still running" and ends "; stopping them."; the model quoting it does
  not count), keeps nothing of the pass: the job says `pass failed`, the run ends `failed:` with
  exit 1, and the next run addresses the PR again. Before, such a pass counted as done and the
  skip rule hid its open thread for good. After `jobs.comments.max_failures` (3) failed passes in
  a row, whatever they changed on the PR, the job stops trying it and the owner is told once; a
  pass run by hand that completes lets the job try it again.
- A failed or cut-short pass leaves `comments-resume.md` in the item's reports, in the shape of
  the health job's `resume.md`: when it was cut short, that the worktree may hold its
  uncommitted work, and to read `git status` and `git diff`, continue from there, build and test
  before committing, and discard nothing without saying so in the reply. The next pass's prompt
  names it, the comments skill and the comment-addresser read it, and a completed pass removes
  it once the claimed worktree is clean. A dirty worktree with that note is no reason for the pass to stop. A claimed worktree
  found dirty with no note (a pass cut off before 1.19.0) gets one before the pass, but only when
  the worktree's claim names the item.
- The host's output goes to `comments.log` as the pass runs, so a pass killed half way keeps
  what it said. There is still no timeout on a pass.
- An open review thread is never hidden by the skip rule. The skip state now holds the
  unresolved thread count, their comments, and the last comment ids of the threads still
  awaiting a reply, as well as the last update, head commit and mergeable state. A thread awaits
  a reply when its last comment does not carry `<!-- flow:reply -->`, the marker
  `comments.sh reply` now adds, so a thread the owner answered under the flow's own login still
  counts. In a thread with no marker at all, a last reply by the flow's login is taken as ours, so
  replies posted before 1.19.0 do not count as waiting; the login is read once per run, and only
  when such a thread exists. Threads still awaiting after a pass get one more pass, then wait until something
  changes, and the owner is told once. `comments.sh activity <pr>` prints what is compared.
  The first run after the upgrade addresses each open PR once, since the compared state changed:
  a thread an earlier cut-short pass left open gets its pass then.
- The comments job skips an item waiting at a gate other than merge: the pass would stop at it
  again. A named PR still runs.
- The comments skill waits for each addresser in the foreground and never ends its turn while
  one runs.
- A plan step that makes tracker tasks of a task splits it. When the plan step ends done or at
  the decomposition gate (not an ambiguity or plan-approval gate: the plan is not settled) with `plan.md` saying `Decomposition: tracker tasks` and children open, `advance.sh`
  runs `steward.sh split <item>`: its step becomes `split`, no profile runs it, it is never
  ready, the board shows `split, waiting on N children`, and `next.sh <item>` says it waits
  (exit 4), or, once every child is closed, to close it (exit 6; the next job says so and the
  health job notifies once). Its worktree goes back to the pool through the steward. It stays,
  with the claim's step set to `split`, while it has uncommitted changes, a run is in flight, or
  a live session works in it; the event says which. Each split is one `split` line in
  `events.log` and a comment on the item.
- Clearing the decomposition gate never splits by itself, whatever children exist: a plan in
  local phases, or a child filed by hand, is left alone. The decomposition gate of a split item
  says how to keep it whole: close the children, then clear the gate, and the plan step runs
  again. The choice is kept (`<flow home>/kept-whole/<slug>`, `steward.sh keep-whole`): until the
  plan step rewrites `plan.md`, neither `advance.sh` nor the health job splits the item, whatever
  children turn up.
- The implement step of a task in tracker-tasks mode with children still open runs
  `steward.sh split` and stops; `advance.sh` keeps an item split during its step split, and
  frees the worktree once the run ends. With every child closed it checks their PRs merged, else
  stops at an ambiguity gate.
- The rule for a split parent's branch: it is kept whenever it holds commits past the base
  (release never forces a delete), and the event names it with its commit count. `release` now
  deletes a branch only when the base holds all of it: `git branch -d` alone also deleted one
  merged into its upstream but ahead of the base. The children
  start from the base and open their PRs against it, since the parent no longer has a claimed
  branch. A child that needs the parent's commits (an ADR, a design doc) names the parent's
  branch in its `## Notes`, the other children block on it, and its implementer merges the
  branch in, so its PR carries them. Delete the parent's branch once they have landed.
- The health job finishes a split the plan step could not: a task at step `plan` or `split`
  whose `plan.md` says tracker tasks, with open children, no gate and no live run, after a dead
  run had its resume. So parents split before 1.19.0 free their clean worktrees on the first
  health run. An item at any other step is never split by the health job.
- The health job looks under a gate. A claimed item waiting at a gate whose worktree has
  uncommitted changes is said and notified once ("an interrupted run left them"); at the merge
  gate, review threads on its PR still awaiting a reply are said and notified once, since the
  comments job addresses them next. Nothing is touched.
- A child takes its parent's priority and area. `new.sh --parent` reads the parent and passes
  its priority and area unless the child names its own, and says so on stderr; a parent it
  cannot read is warned about and the child is made without them. A child left without the
  priority `github.ready_needs` asks for is said too, since it is never ready until one is set.
  `new.sh` and both adapters' `create` take `--priority` (the `github.fields.priority` field on
  GitHub, a `priority` key on a local item). Children made before 1.19.0 keep no priority: set
  it on the tracker.
- Items carry `area` (from `github.fields.area`) and `priority`, and local items carry
  `open_children`, as GitHub items already did.
- The gitignore block `flow:init` writes lists `.flow/*.lock/`, so the `answers`, `pick` and
  `sweep` lock directories no longer show as untracked. `init --check` names each line the
  project's block lacks and exits 1; run `flow:init` to add it.

## 1.18.0 (2026-10-25)

- `gate.sh list --json` prints the pending gates as one JSON array, oldest first. Each gate has
  its item, gate, message, time and host, the claimed pool worktree (or null), its age in
  seconds and its questions. A numbered line opens a question; `Recommended:` (on that line or
  the next, `**Recommended:**` and `- Recommended:` too) starts its recommended answer, which
  runs to the next numbered line. The console will switch to it, so a gate message is parsed in
  one place.
- An empty `questions` means the message is not numbered questions (a plan-approval or merge
  gate, say): the reader shows `message` itself.
- A gate record that is not JSON is skipped with a warning naming the file; the others still list.
  `gate.sh list` with an unknown argument exits 2 with the usage.
- `FLOW_NOW` (an ISO time) stands in for the clock in the age. It exists for tests.
- `gate.sh list` without `--json` prints as before.

## 1.17.0 (2026-10-24)

- The comments job skips a PR with nothing new. Before a pass it reads the PR's last update,
  head commit and mergeable state, with no model. When they match the last pass's, the PR is
  skipped and the run is quiet. A failed pass is tried again, and a named PR always runs.
- A pass's own replies count as new, so one quiet pass follows each working one.
- Quiet runs now cost no model time, so the comments schedule can drop from every 30m to
  every 5m or 10m. An owner's answer on a PR is then picked up within minutes.
- `comments.sh state` also returns `updatedAt`.

## 1.16.0 (2026-10-24)

- The health job merges the base in. A clean task branch with no live run, no PR and no gate, more than
  `jobs.health.behind_base` (20) commits behind its base, gets the base merged in as
  `chore: merge <base> into <branch>`, under the pick lock. No notification: one log line.
- A merge it cannot make goes to an agent. A base merge that conflicts is aborted, and a branch
  diverged from its remote is left as it is. Either way the refs to merge go in `sync.md` in the
  item's reports. The item's next run is then the new `sync` step: the implementer merges each
  ref (never a rebase or a force push), resolves the conflicts, runs the tests they touch,
  commits and pushes when the remote branch exists. The item's own step follows.
- `sync` is in no profile and never moves the item's step. Done drops `sync.md`. Two intents
  that cannot both hold raise the ambiguity gate; checks that stay red raise an escalation gate.
  `sync.md` stays for the run after the gate clears.
- A branch with a PR is not merged into: a conflict with its base is the comments job's. The
  branch flags no longer notify, and `health.md` no longer carries them.

## 1.15.0 (2026-10-23)

- Slack notifications are Block Kit lists (`scripts/_slack.py`). Numbered questions stay
  numbered with the recommendation nested under each, long prose breaks into one bullet per
  sentence, and ids, commits, paths and code names read as code. The plain text stays as the
  push preview; a tracker link that is not https is left out of it.

## 1.14.0 (2026-10-23)

- The reviewers are config. `reviews.reviewers` lists who each review round asks: `codex`,
  `claude`, `copilot` or any GitHub login (default codex and claude, as before).
  `comments.sh request-review <pr> <ask>` asks each in its own comment with a marker; Copilot goes
  through the reviewers API. The pr-creator and the comments step call it and never write a
  mention by hand.
- A silent reviewer is chased. `comments.sh reviews <pr>` reads each reviewer's last request and
  whether it is answered: a review or comment after it, a +1 on it, or a finished Codex summary
  for the head. A Codex summary stuck on running, or a usage-limit reply, is no answer.
  `comments.sh chase <pr>` asks again with the reviewer's trigger phrase once
  `reviews.chase_after` (1h) passes, at most `reviews.max_chases` (2) times, then sends one
  `review-stalled` notification. The comments job runs it before each PR, with no model.
  Copilot's requests are read from the PR timeline and re-asked through the reviewers API;
  each re-ask is also counted in the flow home, because GitHub may record none while the first
  request is pending. Only a bot account speaks for codex, claude or copilot. Drafts are not
  chased: they wait on the quiz.
- A PR that conflicts with its base is fixed. `comments.sh state` carries `mergeable`, the job
  names a conflict in the brief, and the comments skill's new Conflicts step merges the base in
  the task worktree (never a rebase or a force push), verifies, pushes and re-requests review.
  A conflict only the owner can settle raises the ambiguity gate.

## 1.13.1 (2026-10-22)

- `next.sh` no longer stops at "no free worktree" while an item that already holds a claim is ready.
  A pick whose claim finds the pool full skips that item and tries the next ready one: one that
  holds a claim, or whose step needs no worktree. So a full pool keeps working through its claimed
  items. It exits 3 only when every ready item left needs a new worktree. Naming an item still
  exits 3 when it has no room. The retry reuses the ready list it already read, so a skipped item
  costs no tracker call, and a `FLOW_NEXT_SKIP` set by the caller is ignored.

## 1.13.0 (2026-10-22)

- A `health` job checks the worktree pool and the gates every 15 minutes and spends no model while
  all is well. `steward.sh health [--dry-run] [--host H] [--wait]` does the work, so it also runs
  by hand; `jobs/health.sh` adds the lock, the pause and the log, and `jobs.sh` lists, runs,
  pauses and schedules it like the others (`jobs.schedule.health`; the config `flow:init` writes
  sets `every 15m`). Per claimed worktree, in order:
  - Heartbeat. A run is alive when the pid its record names still runs the unattended loop or the
    host session, or an agent works in the worktree, or an agent or the loop names the worktree or
    the item. An editor, a `tail` or the claude daemon naming the worktree is not a run. A record
    with no live process for `jobs.health.grace` (10m) is a dead run: the record goes. When `ps`
    fails or lists nothing, no run is judged dead: the claimed worktrees are left as they are and
    the job says so once.
  - An empty claim (no run, no gate, a clean tree, no commit past the base, no step result, quiet
    for the grace) is released with `release`, never `--force`.
  - Work with a dead run is resumed through `run-unattended.sh` with the item, once per run, at
    most `jobs.health.max_resumes` (3) times in a row while the step does not advance, then an
    escalation gate. The resumed step's brief carries a note, in that one brief only. The resumed
    run logs to `log/resume-<item>.log`. Nothing is reset, stashed or discarded.
  - Branch sync for a clean tree and no live run: fast-forward when only behind the remote branch,
    push when only ahead of one that exists and `jobs.health.push: true` (off by default: the
    job says once that the branch is ahead; never a new remote branch, never forced). A diverged
    branch, or one more than `jobs.health.behind_base` (20) commits behind the base, is only
    flagged: a notification and a note in the item's reports that the next brief carries. A free
    worktree follows the base tip. A dirty or running worktree is never synced.
  - A gate pending past `jobs.health.gate_reminder` (24h) gets one reminder per interval.
  - A full pool that the last `next` run could not start in is said once, with who holds each
    worktree and why.
- Each fact is one line in the job log and in `events.log`; a state already said is not said again.
  Nothing to do is one `quiet:` line and no notification. The notify event is `health`;
  `notify.health: false` turns the notifications off.
- The run record carries the `pid` of its owner: the unattended loop (it exports `FLOW_RUN_PID`)
  or the host session that called `next.sh`. A record without one, from an older flow, is read by
  scanning the processes. Run `flow:init` again to get the loop that records it.
- The board prints `dead run` for a record with no live process instead of `running on <host>`,
  and a `## Health` section when a run is dead or a gate waits past the reminder.
- `notify.sh --event <name> --no-log <message>` skips the events.log line for a caller that logged it.
## 1.12.0 (2026-10-19)

- The retro job commits the lessons log. After each run, quiet or not, `lessons.jsonl` and
  `retros.log` are committed alone on the base branch in the main worktree and pushed, so a cloud
  session reads the same lessons. As with the notes: only when the main worktree is on the base
  branch, a file git ignores is left out and said, the push waits for the owner when the base has
  other unpushed changes, and a failed push is retried by the next run. `retro.commit: false`
  turns it off; the config `flow:init` writes names it.
- The commit and push both jobs share is `job_commit` in `jobs/_job.sh`; intake's commits and
  messages are as before.

## 1.11.0 (2026-10-19)

- `steward.sh sweep [--dry-run]` frees the worktrees whose work landed. A claimed worktree is
  released when its item is closed or its linked PR is merged. On a merge it clears the merge
  gate with the PR's URL and closes an item the merge left open, as a PR into an epic branch
  does. It deletes a squash-merged task branch only while the branch tip is the PR's head, so a
  commit made after the merge keeps the branch. It leaves alone a worktree with uncommitted
  changes, a run in flight, or an item it cannot read.
- The scheduled `next` job runs the sweep each time, after the tracker answers and before a
  worker claims. Merging on the host is now the whole answer to the merge gate.
- `comments.sh state` also prints `headRefOid`.

## 1.10.0 (2026-10-18)

- Intake has two new outcomes. `answered`: a question note is answered from the code and the
  docs, and the job appends the answer to `intake.answers` (default `answers.md` beside the
  notes) instead of filing an item. `dropped`: only with a reason the owner can check, appended
  to `intake.dropped` (default `dropped.md`). A row without its answer or reason is kept. No note
  is parked: `#parked` is a plain tag. Both pages are committed with the notes file, unless git
  ignores one: that page is left out and the notes file is still committed.
- A parsed note carries its title, tags, `^id` handle (a caret at the start or after a space),
  `#dup (see ^id)` and `rel:` handles, and what the ledger holds for those handles: each one's
  outcome, items and the reason it was dropped or done. They are read again before each session,
  so a note links the notes filed earlier in the same run. The skill maps the tags to issue
  types, files a `#dup` as a duplicate, drops a `#dup` of a dropped or answered note with a
  reason that names it, and links related items.
- Each intake session gets the tracker's issue types and area options (`vocabulary.sh` on
  GitHub). `new.sh --area` sets the `github.fields.area` issue field, or the local item's area;
  the skill picks the area from the note's section.

- How a note becomes an item is the project's: the outcome rules, the tag-to-type table, the
  area, size and priority rules and when a note needs the owner live in a rules file, which each
  session reads first. `intake.rules` names it, else `.flow/intake.md` when it exists, else the
  plugin's `skills/intake/rules.md`, flow's defaults: copy it to `.flow/intake.md` to change
  them. An `intake.rules` that names a missing file fails the run before any session.

## 1.9.0 (2026-10-18)

- The `jobs` skill and `scripts/jobs.sh` run and watch the scheduled jobs: `status` shows each
  job's schedule, state, last run with its length and result, next run and the last 7 days'
  counts; `history`, `logs`, `run`, `stop`, `pause`, `resume`. `install` writes and loads the
  schedule from `jobs.schedule.<job>` in `.flow/config.yaml` (`every 30m`, `daily 02:00`,
  `weekly sun 03:00`, then the job's args): launchd agents on macOS, the crontab lines
  elsewhere. `jobs.host` picks the host.
- Every job run is one line in `<flow home>/log/runs.jsonl`: start, length, exit and its last
  words, also for a run a live lock skips and a job that dies after it starts.
- A paused job's runs exit at once, before any tracker call or model spend, and the schedule
  stays loaded. The init config and hints, and `do`, point at the skill. Re-run `flow:init`.
- A schedule's args are checked (plain options and values only) and shell-quoted, and its times
  must exist; cron refuses an interval it cannot keep steady. A lock whose pid a restart gave to
  another process no longer counts as a running job, and the ledger rotates without losing a line.

## 1.8.0 (2026-10-17)

- Answer a gate on GitHub: a comment after the gate's comment that starts with `/answer` (alone:
  as recommended). The scheduled next job clears the gate with those words, reacts +1 and can
  pick the item in the same run. Only the authenticated user counts, or `github.answer_from`.
  The merge gate is not answered this way. Slack's gate notice says how.
- A cleared gate keeps its question and answer in the item's state, and the next step's brief
  shows them; before, the answer reached only a comment the next agent never read. A single
  GitHub read now always fetches the state comment, since an unstarted item has no flow label.
- `intake.notes` may be a path in the repository. A tracked notes file is committed alone and
  pushed after the run when the main worktree is on the base branch and nothing else is
  unpushed, so a cloud session reads the same notes; `intake.commit: false` turns it off.

## 1.7.0 (2026-10-17)

- A gate notification names the item by its id and title. Slack links it to the tracker and
  says how to answer; the desktop shows the title as the subtitle. The message keeps its lines.
- Ambiguity questions have one format, set in the step brief, the gate skill and intake:
  numbered, one per line, each followed by `Recommended:` with the agent's answer and why. The
  owner can reply "as recommended" or change one.

## 1.6.1 (2026-10-17)

- Unattended sessions start a skill as the owner would type it (`/flow:intake ...` on Claude,
  `$intake ...` on Codex) through `host_skill_prompt`, in the intake, comments and retro jobs
  and in the unattended loop's skill steps (design, implement, review, explain). Those skills
  are user-invoked only, so a prompt asking the model to invoke one was refused and the session
  did nothing. The loop template changed: re-run `flow:init`.
- Intake removes a note without touching the blank lines elsewhere in the file, and sets a
  parent only when the note names the epic, since a sub-item holds its epic open.

## 1.6.0 (2026-10-17)

- The intake job and skill: `jobs/intake.sh <host>` reads the next notes from `intake.notes`
  (at most `intake.batch`, default 10) and runs the `intake` skill in a fresh session per note,
  one after another. The skill files the note as a typed, sized item with a suggested priority
  in its notes (never the priority field), names the open item it duplicates, and gates a note
  that needs the owner with `ambiguity` and its questions. After each session the job records
  the note in a ledger and removes it from the notes file by its exact text; `--keep-notes`
  reads a file without changing it.
- `jobs.permission_mode` (`dontAsk`, the default, or `auto`) sets the Claude permission mode of
  every unattended session. Under `dontAsk` without an allow list a run cannot edit a file;
  `auto` lets the classifier allow the safe tools.

## 1.5.1 (2026-10-17)

- An item with open native sub-issues is not ready, so an epic is never picked for its closeout
  while its tasks are open; its project card shows In progress. The GitHub query reads each
  issue's sub-issue summary for it.

## 1.5.0 (2026-10-17)

- The GitHub adapter lists and reads issues through one paged GraphQL query: labels, native
  parent, blockers, issue type, issue field values and project cards in one call per page, not
  one per issue. `github.limit` defaults to 500 and the list says when it stops there.
- Kind comes from the issue type (Epic, Bug, else task) before the labels. A `Parent: #N` line
  with a colon names the parent too; the native sub-issue parent wins.
- Opt-in keys under `github:` in `.flow/config.yaml`: `types`, `fields.size`, `fields.priority`,
  `priority_order`, `ready_needs`, `project` and `status`. With them the size lives in the issue
  field instead of a `size:` label, `flow:new --type` names the issue type, an unstarted item
  lacking a `ready_needs` field is not ready, ready items go highest priority first (also on the
  board), and the project card's Status follows the flow state: gate Needs you, merge gate In
  review, a started step In progress, ready Ready, else Backlog.
- `adapters/github/sync.sh [id]` brings the project in step; `write-state` runs it for its item
  and the next job runs it once per schedule.
- The query asks for issue field values only when a field is configured, and for project cards
  only when `github.project` is set, so a login without the `read:project` scope still lists.

## 1.4.0 (2026-10-17)

- The wrappers under `.flow/` hold no path and no version. Each sources the new `.flow/plugin.sh`,
  which finds the installed plugin when the wrapper runs: `$FLOW_PLUGIN`, else the newest flow in
  the Claude plugin cache, else the newest in the Codex one (exit 2 when neither has it). A plugin
  update no longer changes committed files or leaves the wrappers on the old version, and a clone
  on another machine works as is. Run `init` once and commit `.flow/` to move a project over.
- The stamp's source hash leaves out the manifest, so a version bump alone is no drift.
- The session-start hook stays quiet when the plugin changed but the copies still match.

## 1.3.1 (2026-10-17)

- `init --check` reports missing Claude worktree hooks as a gap when the project has a `.claude`
  folder: `.claude/settings.json` (or `settings.local.json`) must name both
  `worktree-create.sh` and `worktree-remove.sh`. Init still only prints the entry; the file is
  the owner's.
- The session-start hook says so too, on every session, so a branch from before the flow was set
  up (no hooks in its settings) shows at once.

## 1.3.0 (2026-10-13)

- `steward.sh prune [--dry-run]` deletes the reports of closed items. Reports outlive the
  release, so they piled up in every worktree. It looks in the main worktree and every pool
  worktree, and keeps the folders of open items, of claimed items, of items it cannot read, and
  of folders that are not an item's (it names those). The steward skill lists it.
- A release of a closed item deletes its reports in every worktree, so `prune` is only for
  what was left before.
- `steward.sh reports <item>` prints the item's reports folder: the claimed worktree's, else the
  one that exists, else the main worktree's. Skills run outside `next.sh` (review, comments,
  explain, verify, test, pr, implement, plan) take it from there, so a standalone run no longer
  writes to a folder of its own naming (a bare `298` beside `gh-298`) or in the wrong worktree.
  An id that is not an item's fails with exit 2.

## 1.2.0 (2026-10-11)

- Gates in `.flow/config.yaml` take `paths`. `name: command` still always runs. A map with
  `command:` and `paths:` (globs) runs when a changed file matches one, else the report lists the
  gate as skipped.
- Slack: `FLOW_SLACK_WEBHOOK` in the environment supplies the webhook, so the URL stays out of
  the repository. `notify.slack_webhook` is the fallback.
- Mutation in `verify`: an empty `mutation` in `.standards/config.json` is off and shows as a
  skipped check. A command with `{files}` runs on the changed source files only and is skipped
  when none changed.
- `notify.idle: true`: the scheduled `next` job sends one notice when it finds nothing ready, then
  stays quiet until a run does work again. `notify.sh --event <name> <message>` sends a notice
  that is not a gate (no gate record).
- Parallel unattended runs. `jobs/next.sh <host> --workers N` starts N loops, each on its own
  ready item and worktree, each with its own lock and log (`next-1` ... `next-N`). A worker
  still busy from the last schedule is skipped. A full pool stops a worker quietly (exit 3).
- The pick lock. `next.sh` picks the item, claims the worktree and records the run under one
  lock (`<flow home>/pick.lock`), so runs started together never take the same item or
  worktree. A busy lock waits up to `FLOW_LOCK_WAIT` seconds (60), then exits 7; a lock whose
  holder died is taken over.
- `do` starts unattended runs from plain words: "start a one-off unattended run" runs the job in
  the background; "run a repeating unattended flow every 30 minutes" creates a scheduled task
  where the host has a tool for it, else gives the command and cadence for the owner's scheduler.
- `init` no longer writes `pool_max: 3` over a longer pool. When the repository already has more
  than three worktrees, `pool_max` is their count and `init` says that every one becomes a task
  slot.

## 1.1.0 (2026-10-11)

- `do`: the front door. A model-invoked skill that takes a plain sentence ("what is stuck?",
  "start the bots bug", "approve the plan for 312"), finds the item by its title, asks once before
  anything that runs agents or clears a gate, and follows the matching skill.
- `help`: a manual read from the installed plugin. `help` lists every skill with how to call it on
  Claude and Codex; `help <skill>` shows one; `help lines` and `help gates` show the steps per
  kind and size and what each stop asks of you. `scripts/help.sh` does the work.
- `auto_gates` in `.flow/config.yaml`: `plan-approval: S,M` lets the flow clear the plan-approval
  gate itself for those sizes (logged on the item and in `events.log`). Merge, interview,
  decomposition, feel-test, escalation and ambiguity, and a re-size gate, always wait. `init`
  flags any other name as a gap.
- `gate`: a skill to list the gates waiting on the owner and to answer one (`gate.sh clear`), so
  approving a plan, a spec or a task list is a command, not a script path.

## 1.0.0 (2026-10-11)

First stable release: the config keys and the hook contracts are kept from here on.


- `new`: a skill and `scripts/new.sh` create an epic, task or bug in the tracker the config names
  for the kind, with the item body shape, a size, blockers and a parent. Agents working a
  backlog use it for follow-ups; the planner creates sub-items through it.
- The pool grows on its own: a claim with no free worktree adds one while the pool is below
  `pool_max`, named after the last entry, appends it to `pool:` in `.flow/config.yaml`, copies
  the git-ignored files in `worktree_copy` from the main worktree and runs `worktree_setup`
  there. `steward.sh add [path]` does the same by hand; `steward.sh setup <path>` re-runs the
  copies and the commands. At `pool_max` the claim still fails with exit 3.
- `init` reports `Gaps` (an empty pool with `pool_max` 0, an empty base, an adapter that does
  not exist) and `init --check` counts them as drift; the config template carries `pool_max`,
  `worktree_copy` and `worktree_setup`, and the init skill asks the owner the config questions
  with a recommendation each.

## 0.2.0 (2026-10-11)

- The agents and the step skills read the testing guide at `.standards/testing-guide.md`
  (standards 0.2.0 moved it out of `docs/`).
- `init` writes `.flow/stamp`, refuses to replace a guarded copy edited by hand (`--force`), and
  a `SessionStart` hook asks for `init` when the stamp is behind the plugin. `init` writes only
  under `.flow/`, plus `.codex/rules/flow.rules`, `.codex/agents/` and the `.gitignore` block.
- Scheduled jobs: `comments`, `next` and `retro` under `.flow/jobs/`, with a lock and a log each.

## 0.1.0 (2026-10-10)

- First release of the rework: adapters, profiles, next/advance, the steward, gates, the board.
