# flow

## 1.38.0 (2026-11-11)

- A gate carries what the owner needs to act on it (gh#170, ADR 0003). The gate's record in the
  flow home gains `options` (the answers the agent offers, each `{label, text, recommended}`, 1 to
  9, at most one recommended), `raised_by` (`step <step>`, `health job`, `comments job`, `intake
  job` or `owner`), `answered_by` (who carries the answer out), `condition` and `footer`.
  `gate.sh list --json` appends them, with `[]` and null for a record from an older plugin.
  Tracker state keeps `gate` and `gate_from` only, so no adapter changes. The tracker comment and
  the notification end with the footer: who answers and the exact `gate.sh clear` command, so a
  host with no record still knows how to answer.
- `gate.sh raise` takes `--options <json>`, `--condition <condition>` and `--raised-by <who>`. A
  malformed options value or a condition outside the grammar is dropped with a warning and the
  gate still raises. A step's result file may set `options` and `condition` with status `gate`,
  and `advance.sh` passes them on.
- `gate.sh clear <item> --option N [note]` answers with option N's text, the note as a second
  paragraph. It refuses, exit 2, with no record on this host, no options, N out of range, or
  `--back` beside it. Every clear of an item takes a per-item lock, so the owner and the health
  job never clear one gate twice.
- A gate can wait on a condition the health job watches: `blocked_by:<item>` (that item closes),
  `pr:#N conflicting` (the PR no longer conflicts) and `ci:down` (the item's PR has no failing
  check). Each pass `steward.sh health` clears a gate whose condition ended with
  `gate.sh clear <item> --met <condition>`, which carries nothing out and leaves the step as it
  was, so the next job runs that step again with no escalation; it refuses, exit 1, when the
  record now waits on another condition than the one health read. A tracker it cannot read keeps
  the gate.
  The reminder on such a gate names the condition. A `blocked_by` id must be one an adapter owns,
  in its shape (`item_id_shaped`), at raise and again when the health job reads it.
- Security: `adapter <op> <name>` takes an adapter name only as a folder under `adapters/`, never a
  path, and exits 2 otherwise; before, an id no adapter owned fell through to
  `adapters/<id>/<op>.sh`, so a crafted `blocked_by` condition or `hold.behind` could run a script
  outside the plugin.
- The pr step stops at an open blocker with an ambiguity gate that waits on `blocked_by:<blocker>`
  and offers "Open it now", instead of failing until an escalation. Every fail or gate names the
  command or tracker action that unblocks it, so the escalation quotes it. The health, comments
  and intake jobs name themselves as the gate's raiser; the comments job's conflict gate waits on
  `pr:#N conflicting`.
- Picking an option on a gate that waits on `blocked_by:<blocker>` (`gate.sh clear <item>
  --option N`, the pr step's "Open it now") waives that blocker for the item, in
  `<flow home>/waived/<item>`: `next.sh` and the ready filter no longer hold the item behind it,
  so the step runs while the blocker is open and carries out the answer. An answer in words
  waives nothing. No tracker state changes (ADR 0003).
- The board's "Waiting on you" bullets end with who raised the gate, who answers it and what it
  waits on, when the record has them.

## 1.37.0 (2026-11-11)

- The Codex model map follows the current Codex catalog (`codex debug models`, Codex CLI
  0.166.0): opus runs as `gpt-6.1-sol`, the current workhorse, and sonnet as `gpt-6.1-terra`, the
  balanced tier below it; fable stays `gpt-6-astra` and haiku `gpt-6-luna`. `gpt-6-sol` is the
  previous generation. `host_codex_model`, the roster's Codex agents and the init example change
  with it. A `jobs.codex.model` set by hand is passed on as is, as before.
- A session that fails because its host does not know the model stops the host, as a spend limit
  or an auth error does: `_host.py` reads claude's `unrecognized_model` ("There's an issue with
  the selected model") and Codex's `model_not_found` as the cause `model`. The unattended loop
  raises one escalation gate that names the model and the fix, and no session starts on that host
  until it clears. Before, each item on a bad model spent its attempts and raised its own gate
  (gh#169 made those failures count).

## 1.36.0 (2026-11-10)

- A claimed item waits at every step while a native blocker is open (gh#168). An owner can block
  an item after its claim (`blocked_by` on the tracker), and `next.sh` used to start its step
  anyway: the agent refused, the flow counted a failure and, after three, raised an escalation
  gate. Now `next.sh` passes the item over with "<item> is held behind <blocker> (blocked by)",
  exit 4 when it is named, and records no run, so no attempt is counted and no escalation follows.
  A pick that finds nothing names a claimed blocked item among the held ones, "<item> behind
  <blocker> (blocked by)". Once the last blocker closes, the item's own step starts again, after
  a sync step when one is due, and its brief says to merge the item's base first.
- The ready filter's notes add `blocked_by`, the open blockers, to an item it held back as
  blocked.
- The board shows each item's open blockers, not every edge: the text board's `blocked by` column,
  and `open_blockers` on every item of `board.sh --json` (the tracker's own list, else each
  blocker not read as closed). A blocker the lists leave out is read once, as `next.sh` reads it,
  so one that cannot be read shows as open on the board while `next.sh` holds the item behind it.
- An unattended step whose session ends with no result file (every write denied, or it stopped
  short) is a failed attempt, not a silent stop (#169). The run writes the fail result for it,
  quoting the session's last message, so `advance.sh` counts the attempt, comments on the item and
  raises the escalation gate at `max_attempts` as for any fail. The result keeps the claim, so the
  health job no longer releases it as empty and the item no longer loops back to ready unseen. A
  result left from an earlier session no longer stands for one that wrote none. `host_run` sets
  `host_last`, the session's last message.

## 1.35.0 (2026-11-08)

- A cleared gate's answer is never dropped in silence (#157). `gate.sh clear` records what carries
  the answer out in the new state key `answer_pending`: `next` when the item's step is one next
  runs, or `comments` when the item is at `done` with an open PR. The clear says which, so it no
  longer tells the owner to run `next` on a done item. An answer no step acts on (an item at
  `done` with no PR, or with a merged or closed one) fails with exit 1 and keeps the gate: "no
  step acts on this answer", do it by hand, then clear the gate with no answer. A send-back to
  `done` fails the same way. The merge gate, a clear with no answer and a decomposition gate that
  lets a split stand carry nothing out.
- The comments job names a waiting answer in the pass's brief ("The owner answered the <gate>
  gate: ..."), always gives it a pass, and takes it only when the pass confirms it carried the
  answer out or raised it again as a gate. It confirms by writing the answer's time to a file the
  brief names. A pass that ends without that is a failed pass, and the answer stays pending. A
  newer answer that came while the pass ran is kept for the next pass. The comments skill gains an
  Answer step: it carries the answer out on the PR's branch, or raises an escalation gate when the
  answer asks for work elsewhere, such as merging main into the PR's base. Before, a gate a
  comments pass raised on a done item was cleared and nothing read the answer.
- `next.sh` takes the answer when it starts the step whose brief carries it. On a done item whose
  answer waits on the comments job, it says so instead of "merge or close it".
- The board shows a waiting answer in the gate column (`none, answer waits on the comments job`),
  and in Health once it has waited past `jobs.health.gate_reminder`.
- Adapters: `answer_pending` is a new state key on github, jira and local.
- The implementer brief: a method writes an argument only when its name says so (M-08), even
  where the file around it threads state through `ref`.

## 1.34.0 (2026-11-08)

- The `health` job cleans a free pool worktree whose uncommitted changes are already in the base
  branch's history. `scripts/_redundant.py` checks each changed path. Its content and mode, both
  staged and on disk, must be a version the base's history gave that same path, or the path is
  deleted. The worktree's commit must also be in the base. The first run that finds such changes
  names them once. The next run discards them if they are unchanged and no session works there, the
  one that called health included. It checks again, restores only the checked paths and removes only
  the checked untracked files, so `.flow/` is never touched. It notifies the owner, and a claim can
  use the worktree again. A free worktree once sat for four days holding a stale index from before a
  squash merge. Health said so once, and the pool ran one worktree short.
- Changes with anything of their own stay. A conflict, a submodule, an untracked file or a version
  the base never had all count, as do more than 200 changed paths, a git command in progress or a
  file that cannot be hashed. Each file is hashed on its own, so any file name is safe, and from its
  raw bytes, so a clean filter or an end-of-line rule cannot hide bytes only the disk holds. The
  health line now names the first such path: `wt-2 is free but has uncommitted changes, so no claim
  can use it: the disk version of README.md is not in origin/main`.
- The health job sweeps the planned holds (`state.held_by`): a hold whose holder cannot be read or
  found, holds no worktree and has no run, or whose `changes` no longer share a path with the held
  item's is cleared, as is a hold on the item itself and the newest hold in a cycle. A holder with
  no `changes` (a bugfix or an S task) is judged by its `touches`; with neither, the hold stays. A
  hold whose holder closed stays, so `next` releases it with the note to merge and recheck the plan.
  Each clear is a line in the health result and an `unheld` line in `events.log`. A valid hold
  waiting over a day is said and notified once. Only the holders no tracker list holds are read, one
  read each.
- A `next` run with no item named works on after a gate: the item at the gate is set down and
  the run picks the next ready one, until `--max-steps` or nothing is ready, so a worker no
  longer sits idle until the next schedule. It ends as a gate (exit 4), and the job
  says it stopped at a gate with every step it ran. A named item still stops at its gate, and an
  escalation gate or a stopped host still ends any run.
- `next.sh` no longer skips a ready item whose `touches` overlap a running item's: the check ran
  only against in-flight runs and only for items that had recorded touches, so it kept nothing
  apart and cost parallelism. The plan step's hold (`state.held_by`) replaces it.
- A held item is not ready past its plan: `filter-ready` holds back an item whose `held_by` names
  an item that is still open, read through its adapter as a blocker is. A holder closed or not
  found holds nothing. A named held item exits 4 with `<item> is held behind <holder>: <reason>`;
  a pick passes it over. The plan and the steps before it still run, so a held plan sent back at
  its gate is planned again, and the brief says that plan decides the hold anew.
- Once a claim in a pick finds the pool full, the pick skips every ready item that holds no claim
  and whose step needs a worktree with no tracker read and no claim attempt, and tries the claimed
  ones. One pass with a full pool no longer holds the pick lock long enough for the other workers
  to give up.
- A pick that finds nothing says why on its last line, and the next job's quiet line carries it:
  `no free worktree for the N unclaimed ready item(s), and the pool is at pool_max; the claimed
  items: 2 running, 3 held (gh#1 behind gh#2, ...)`, or `nothing ready: 1 running, 2 blocked`.
  A named held item is a quiet run that names its holder, not a gate.
- `board.sh --json` carries `holders`: the status (`open`, `closed` or `unknown`) of each holder
  an open item is held behind that the open-item list leaves out, read once each.
- The plan step decides holds. Two items conflict only when both change existing behavior in
  the same code and the clash would be hard to resolve; additive work, docs and tests never do,
  and a small overlap in doubt runs in parallel. The rule lives in `skills/plan/holds.md`.
- `scripts/hold.sh candidates <item>` lists the other open items holding a claim whose `changes`
  (or `touches`, lacking changes) share a path prefix with the item's touches, with each one's
  plan report. The plan brief gets an `## Other open work` section only when it lists something;
  the planner checks its final touches with `--touches` before it reports.
- The plan result carries `changes` (the globs among `touches` whose existing behavior the plan
  changes) and, for a conflict, `hold: {behind, reason}`. `advance.sh` writes `changes`, and
  with a hold `held_by`, `held_reason` and a `held` line in `events.log`; the gate and the
  comment say it. A replan with no hold lifts an earlier one (`unheld`).
- `next.sh` lifts a hold once its holder has closed (`unheld` line) and the brief tells the agent
  to merge the base in first, never rebase, and to stop at an ambiguity gate when the plan no
  longer fits.
- A verify run starts on merged code: `next.sh` merges the base into a clean task branch that is
  behind it before the verify step (an `events.log` `sync` line); a merge that conflicts is
  aborted and runs as the sync step first.
- The explorer's design result carries `touches`, so the plan brief can judge other open work
  before the plan exists.
- The retro job finds the new lessons by time: every `lessons.jsonl` line whose time is after the
  last `retros.log` line. A line count missed 26 lessons when a checkout of an old branch that
  still tracked the log rewrote it.
- The test-writer brief: settings, budgets, bounds and messages are read from their owner, never
  copied as literals; no prose pinned; no guard on today's tuning state (step 12, T-01). Step 11
  no longer asks for a separate not-null assertion, which T-09 blocks; chain from it instead.
  Locals and lambda parameters state their role (N-04, N-05).
- The implementer brief: never widen access so a test can reach a member; new implementation
  types start at the narrowest access; locals and lambda parameters are spelt in full; added
  tests read owned values from their owner.

## 1.33.0 (2026-11-06)

- A red check never ends a `comments` pass. The Checks step fixes what is the change's; a failure
  that is not (infra, billing, a flake, a check red on the base too) gets no code change, the report
  says so, and the pass goes on to the threads. Since 1.32.0 an unattended pass stopped there, left
  each thread "for the next pass", and the job gave up on the thread after its one extra pass: with
  CI blocked, no review thread was answered. A fix the verifier rejects goes to a local
  `<branch>-rejected-<sha>` branch and the task branch goes back to its head, so a thread's push
  never publishes it. The job's brief says to run the Checks step, then the threads whatever it
  finds, and to address every thread before it ends.
- The comments job's result line names every open PR and what it came to, instead of counting
  "nothing new" for PRs it had given up on: `quiet: nothing new on 1 PR(s): gh#695; 2 wait on you:
  gh#523 (thread(s) 4470724616 unanswered after two passes), gh#626 (…); 1 in use: gh#416 (claude
  process 62102, idle 3d 2h in app-wt-10); at a gate: gh#7 (ambiguity gate)`. A PR the job stopped
  trying after failed passes waits on you too, with the count.
- The Codex desktop app's servers no longer count as a session in a worktree. `codex app-server`,
  its `app-server daemon` and `exec-server` keep the folder they were started in for days, and the
  comments job skipped that worktree's PR the whole time. Only the subcommand names a server, and
  never in an unattended run, so `claude -p mcp is broken` stays a run. The health scan reads the
  first two words after the executable that are not options, as the console does.
- A Claude desktop session counts as a session in its worktree. The app keeps its CLI under
  `~/Library/Application Support/Claude/`, and ps prints that path unquoted, so the health scan read
  only up to the space and never saw the session. It rejoins such a path as the console does.
- A skipped PR's session is named with how long it has been idle (`claude process 62102, idle 3d
  2h`), from the status Claude keeps in `~/.claude/sessions/<pid>.json`; a host with no status shows
  how long it has run. The owner's notice ends in the kill command.
- `steward.sh sessions [--stale]` lists the claude and codex sessions in the main worktree and the
  pool: pid, host, kind, worktree, the item its claim holds, busy or idle and for how long. One idle
  past `jobs.health.stale_session` (default 24h; with no status, alive that long) is marked STALE
  with its `kill <pid>`. The `health` job names each stale session once while it stays, with what it
  holds back.
- `flow:init` writes `jobs.comments_workers` and `jobs.health.stale_session` into the config it
  makes, commented, so both settings can be found.

## 1.32.0 (2026-11-04)

- The `comments` pass fixes the checks failing on a PR's head. A new Checks step, after
  Conflicts, spawns the `implementer` to read the failed logs, fix the cause in the task branch,
  build and test, then the `verifier`; on a pass it pushes (never force) and re-requests review.
  A failure that is not the change's (infra, a flake, a check red on the base too) gets no code
  change: the report says so, and an unattended pass stops on it.
- `comments.sh failing-checks <pr>` prints the checks failing on the PR's head, one name per
  line, sorted: the latest run of each check only, so a re-run that passed does not count, and a
  pending one waits. `comments.sh activity` carries them as `failing`.
- The comments job names the failing checks and the head in the brief ("Checks fail on
  <sha8>: A, B: run the Checks step."), drafts included. Its activity line ends in
  ` failing:<names>` only when a check fails, so a check gone red on the same head gets one pass,
  one the pass cannot fix is not tried again until the head changes, and a PR with no failing
  check keeps the line it had and gets no extra pass after the upgrade.
- A pool path listed in `.flow/config.yaml` but missing on disk counts as free. A claim (or a
  reserve) recreates it on its idle branch at the base tip, pruning git's stale record of the
  folder first, and runs the `worktree_copy` copies and `worktree_setup`, instead of failing with
  "every pool entry is claimed, reserved, dirty or missing". Two pool worktrees vanished this way
  after Claude worktree sessions ended.
- `steward.sh health` names a missing pool path once while it holds, with the command that
  recreates it now, and counts it as free. `steward.sh add <path>` recreates a missing pool path
  in place without a second pool entry.
- The `WorktreeRemove` hook still only releases: the folder stays, on its idle branch at the base
  tip, with no claim. Claude Code 2.1.317 reads its exit 0 as removed and leaves the folder alone;
  it keeps a sub-agent's hook-made worktree and runs no `WorktreeRemove` for it. A session with no
  `WorktreeRemove` entry falls back to `git worktree remove`, which is how a pool folder can still
  go; the next claim brings it back. The hook's header and the `steward` skill say so.
- `steward.sh reserve [<worktree>] [--name <who>]` takes an optional pool worktree, by its path or
  its folder name, and reserves that one when it has no claim, no reservation and a clean tree.
  A claimed, reserved, dirty or unknown one exits 3 with the reason (`wt-2 is claimed by gh#5`,
  `wt-1 is reserved by Ada`, `wt-2 has uncommitted changes`, `wt-9 is not a worktree in the
  pool`). With no worktree it takes the first free one, as before.
- The comments job tells the owner once when it skips a PR because another session works in the
  item's worktree (`notify.sh --event comments-skipped`): the item, the PR, the worktree and the
  process there, such as `claude (process 4242)`. A `pr-<n>.told-in-use` marker beside the job's
  seen files holds it while the session stays, keyed by the PR number so the item and the PR's
  number name one marker; a pass that addresses the PR clears it, so the next streak is told
  again. No word when the processes cannot be listed.
- The comments job addresses up to N PRs at once: `jobs/comments.sh <host> --workers N`, or
  `jobs.comments_workers: N` in `.flow/config.yaml` for its schedules; unset or 1 keeps one pass
  after another. It stays one run under the job lock, the processes listed once, and its result
  line sums the passes. Each pass holds its item's lock (`<flow home>/item:<slug>.lock`, no
  wait), so no two passes work one item at once: a held one skips the PR, counted in use. A pass
  the stopped host ends lets the passes in flight finish and starts no other; the run exits 1
  when any pass failed. An unknown option to the job is refused, exit 2.

## 1.31.0 (2026-11-03)

- `flow:init` writes the Claude `WorktreeCreate` and `WorktreeRemove` entries to this user's
  `.claude/settings.local.json` instead of printing them for the shared `.claude/settings.json`.
  It merges them into a file that exists (every other key and hook kept), creates the file and
  `.claude/` when missing, refuses a file that is not JSON, and adds the file to the exclude block.
  `init --check` reports a missing or changed entry there as drift.
- The entries only run the main worktree's `.flow/hooks/worktree-*.sh`. The fallback that made a
  worktree as Claude does when flow was absent is gone: a teammate without flow has no entry, and
  Claude makes its own worktree.
- When the committed `.claude/settings.json` still carries a flow hook entry, init's "Next" list
  and `--check` say to remove it and print it. Init never edits that file. Owner action: remove
  the entry from `.claude/settings.json`, commit that, and run `flow:init` once.
- The retro job commits nothing: the lessons log (`.flow/lessons.jsonl`, `.flow/retros.log`)
  stays on this machine under `.flow/`, which git has ignored since init moved it to
  `.git/info/exclude`, so every run had only said it left the commit out. The `retro.commit` key
  goes, and `init --check` names a config that still sets it as unused. The config comment init
  writes and the `jobs` skill say the lessons stay on this machine.
- The pool worktrees' plugin versions follow the newest installed one. Claude pins a plugin per
  project directory, and a linked worktree is its own directory, so it kept the version it first
  saw: `claude plugin update` run inside it reads the main checkout's record, and the marketplace
  auto-update never touches it. The `SessionStart` hook now runs `scripts/_plugins.py sync`, which
  lifts every worktree's record of the repository to the newest version any scope has in the
  plugin cache and says which it lifted; a session sees the new version at its next start.

## 1.30.1 (2026-11-02)

- The claim's step follows the issue's. `advance.sh` and `gate.sh` write each step change to the
  item's claim in the pool too (`step_write` in `lib/flow.sh`), so an item waiting at a gate or
  between runs no longer shows the step that last ran in its claim and the next step on the issue.
  That covers a step done, a failed step sent to its fix step, a re-size, a gate sent back, an item
  kept whole and a finished sync step. The console stops showing these as claim and issue
  disagreements, whose button would have moved the issue back a step.

## 1.30.0 (2026-11-02)

- A claim (or reserve) that would grow the pool with a refused `worktree_name` (no `{n}`, or one
  that gives every number the same idle branch) exits 2 with the template's reason and no pool_max
  message; a full pool still exits 3. Tests now pin both, and the steward.sh header names the
  `worktree_name` template that names a grown worktree.
- `flow:init` leaves no trace in tracking: its ignore block goes to the clone's `.git/info/exclude`
  and covers all of `.flow/`, which every linked worktree shares and nobody commits. `--check`
  reads the block there. The "Next" text no longer asks to commit `.flow/`.
- A repository that committed flow before migrates: init removes the `# flow:begin` block from
  `.gitignore` when every line in it is one init wrote (a block the owner added to is left and
  named), and prints `git rm -r --cached --quiet -- .flow` for the tracked files. It never runs it.
- The `.claude/settings.json` hook entry init prints runs the main worktree's `.flow/hooks`
  wrapper when the clone has one (from a linked worktree too), and otherwise makes the worktree
  as Claude does with no hook, so `claude --worktree` works for a teammate without flow. It
  reuses the `worktree-<name>` branch when one exists, and the remove entry deletes that branch
  when it is merged or unchanged, so a name can be opened again. A
  WorktreeCreate hook that printed nothing would fail the session. `init --check` notes an entry
  an older init printed.
- The Codex rules and agents go to the user's `~/.codex` (`$CODEX_HOME`) with `init --user-codex`
  or when the repository has no `.codex/`, and to the repository's `.codex/` otherwise. A later run
  keeps the place the stamp records, and init says which on its `Codex rules and agents:` line.
  What flow wrote in `~/.codex` is recorded in `~/.codex/.flow-stamp`, which every repository
  installing there reads: a hand edit there, or a file flow never wrote, is refused unless
  `--force`. The stamps keep paths whole, so a home folder with a space in its name works.
- The session-start install check reads the stamp in the main worktree's `.flow`, so a session in
  a linked worktree, which has no `.flow/config.yaml` of its own now, is checked too.
- The Jira adapter answers gates on the issue: `adapters/jira/answers.sh` clears a gate when the
  owner comments `/answer <text>` (or `/answer` alone, as recommended) after its `**Gate: ...**`
  comment. The owner is the API token's user, or an account id or email in the new
  `jira.answer_from` list. The merge gate is left to the merge. `gate.sh` comments "Gate cleared"
  on the issue as the receipt.
- `adapters/jira/vocabulary.sh` prints the project's issue types (no sub-tasks) and the options of
  the `jira.fields.area` field, so `flow:new` offers Jira's own names. Jira has no `sync.sh`: its
  board columns are workflow statuses each project shapes its own way, the `step:` and `gate:`
  labels already show where an item is, and closing takes the done transition.
- Slack notifications know an item id by the adapters' prefix files, so `jira:WID-7` reads as code
  and a new adapter's ids do too. A gate on an item whose adapter has `answers.sh` says to answer
  on the issue; any other gate says to answer in a session.
- `board.sh` shows what it can when a tracker's list fails: the other trackers' items, and each
  failed tracker with its exit code and last stderr line (`tracker_errors` in `--json`, a
  "Trackers not read" section in the text board), where before the whole board stopped or the
  items went missing without a word.
- `init.sh` writes the commented `jira.limit` and `jira.answer_from` keys into a new config.
- `next --pick <name>` takes the first ready item the filter `pick.<name>` in `.flow/config.yaml`
  keeps: `assignee` (`me`, a login or an email), `status`, `labels` and `kinds` (any of each),
  `trackers`, or `query`, one tracker's own search passed as written (JQL on Jira, search
  qualifiers on GitHub). Readiness, blockers, gates and the priority order apply after the
  filter; without `--pick` nothing changes. An unknown name exits 2 naming the filters there are.
- Each adapter maps the fields in `list` and `list-ready --pick <name>` and names them in a new
  `pick-fields` file; a field it cannot map (local has no `query`), a query without exactly one
  tracker or beside a neutral field, and a tracker the flow does not read are refused, exit 2.
  `adapters/README.md` documents the mapping and the contract suite checks it for github, local
  and jira.
- `jobs/next.sh` and `run-unattended.sh` take `--pick <name>`, so a named schedule runs one
  filter: `jobs.schedule.next-mine: every 30m --pick mine`. A bad filter stops the run before it
  reads the tracker.
- The Jira adapter counts a listed epic's open children with a second search when a filter
  narrows the list, so an epic whose children the filter leaves out still counts them.

## 1.29.0 (2026-11-02)

- The quiz the explain step writes is taken in the console, not on the PR. `scripts/quiz.sh show
  <item>` prints `<reports>/quiz.md` as JSON (title, questions, choices, the answer key, each
  question's `Because:` line) with the last result; `quiz.sh answer <item> 1b 2a 3c` (or `b a c`
  in question order) grades it, writes `<reports>/quiz.json`, logs one `quiz` line in events.log
  and on a pass marks the item's draft PR ready (`comments.sh ready`) when it has one on GitHub.
  The console's Gates and Pull requests pages run it from a Take the quiz button and show the
  result with the justifications.
- `quiz.md` is multiple choice only, and every question carries a `Because:` line that says why
  the right choice is right; the explain skill checks the file with `quiz.sh show`. The pr-creator
  still opens a draft while a quiz exists but posts nothing of it on the PR; the comments pass no
  longer grades a comment, and marks a draft ready only when `quiz.json` says the quiz passed.
- The PR body's Merge danger section says what Door and Blast radius mean where they are read:
  Door is how hard the merge is to undo (two-way: a revert undoes it; one-way: it does not, and
  why), Blast radius is what is affected if the change is wrong, in a word or two.

## 1.28.0 (2026-11-01)

- A PR the pr step's worker could not record (a local item file lies outside its sandbox) no
  longer leaves the merge gate stuck. The pr step's result names its PR under `pr`, and
  `advance.sh` records it when the item has none. `steward.sh sweep` finds the PR of an item at
  the merge gate with no PR recorded by its task branch (`gh pr list --head flow/<slug>`),
  records it, and clears the gate once it is merged. A failed `link-pr` no longer fails the step.
- `jobs/next.sh` names what stopped it with exit 2 in its status line, such as the bad
  `jobs.<host>.effort`, not only `stopped: exit 2`.
- The comments, intake and retro jobs end the run when the host is stopped, before a session or
  by one, their status line saying the host is stopped and why. The stop names no item, so
  `gate.sh clear <host>` lifts it: the comments job's item waits at the merge gate, which an
  escalation gate would replace. A comments pass the stopped host refused runs after the clear,
  even when it was the one extra pass for a thread still awaiting a reply.
- The `_job.sh` and jobs skill wording says the model and effort pair also feeds the steps with
  no agent that `next` runs. The jobs skill and the health job say why `health` does not resume a
  run a spend limit or an auth error stopped: its gate ended it, and `next` continues the item
  once the gate clears.
- `init` run from a linked worktree works on the flow home, the main worktree's `.flow`, says so,
  and `--check` reads the same place. With no main worktree to find it refuses and names it.
- `init` proposes as the pool only the linked worktrees under the main worktree's parent folder:
  not Claude's session worktrees under `.claude/worktrees`, nor `.flow/tmp`, nor any elsewhere.
- Missing Claude worktree hooks are a note, not a gap: the flow runs without them, and
  `init --check` exits 0 when they are its only finding.
- `worktree_name` in `.flow/config.yaml`, such as `../{repo}-wt-{n}`, names the worktree the pool
  grows by and the one `steward.sh add` adds without a path: `{repo}` is the main worktree's
  folder, `{n}` the first number no pool entry and no folder uses. Unset keeps the old names. A
  name with no `{n}`, or one that gives every number the same idle branch (`{n}` only in a parent
  folder, such as `../slots/{n}/checkout`), is refused with the reason before anything is created
  (`add` exits 2).
  `init` writes it commented out next to `pool_max`.
- `trackers: [github, local]` names the trackers the board, next, health and the comments job
  read, apart from where new items go (`adapters.default` and `adapters.<kind>`, unchanged). Unset
  keeps today's set: every tracker under `adapters` and local. A name with no adapter is refused,
  exit 2, with the adapters there are. While `trackers` is set, an `adapters` value it leaves out
  is refused by `new.sh` (exit 2) and is an `init --check` gap: the flow would never read the item.
- `ready.needs` and `ready.priority_order` are the readiness rules of every tracker, read once by
  `ready_rules` in lib/flow.sh. The local adapter honours both: an open, unstarted item without a
  needed field lists it under `needs` and is not ready, and `list-ready` follows the order, items
  with no priority last. A field other than priority and size is refused, exit 2, with the fields
  the flow knows (the GitHub adapter only warned). `github.ready_needs` and
  `github.priority_order` still stand in for a key the file leaves out (an empty list written
  under `ready` is kept), now for every tracker, with one warning a run naming the new key.
  `new.sh` says a child lacks the priority `ready.needs` asks for on any tracker.
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
- Jira Cloud is a tracker: `adapters/jira/` meets the adapter contract through the REST API v3
  and `curl`, with ids `jira:<KEY>-<n>`. Set `adapters.default` (or `adapters.<kind>`) to `jira`
  and `jira.site`, `jira.project` and `jira.email`; the token comes from `JIRA_API_TOKEN` in the
  environment only, reaches `curl` on stdin, and without it every script refuses with the reason.
- Each kind is created as the issue type `jira.types.epic|task|bug` (default Epic, Task, Bug). The
  flow state lives in the same labels GitHub uses (`step:`, `gate:`, `wt:`, `flow:`, `size:`) and
  whole in the issue property `flow-state`. The priority is Jira's own; the size is the field
  `jira.fields.size` when set, else a label; `ready.needs` and `ready.priority_order` apply.
- Blockers are Blocks links (a blocker in another tracker is a `Blocked by:` line), `link-pr` adds
  a remote link and a comment, `close` takes `jira.transitions.done` (default the transition named
  Done), and a 5xx or a dropped connection is tried again like `gh`, except for a create.
- `init` writes the `jira:` keys, commented, into a new config. `tests/fake-jira.sh` stands in for
  Jira's `curl`, and `tests/run.sh` runs the contract suite for `jira` too.
- Reviewers per author host. `reviews.reviewers` is one list for every PR, as before, or a map:
  `claude` names the reviewers of a PR Claude wrote, `codex` of one Codex wrote, and `default` of
  a PR whose author host is unknown or has no list (unset, codex and claude). `link-pr` records
  the host that wrote the PR as the item's `pr_host`; with none there, the PR body's footer says
  it. `comments.sh request-review` and the comments job's chase ask the author host's list, and
  `comments.sh reviewers --host claude|codex` prints it. The `pr-creator` brief records the PR on
  the item before it asks for reviews, so the request finds the host.
- `steward.sh reserve [--name <who>]` takes a free pool worktree for the owner's manual work: a
  claim with no item under `<who>` (default: git `user.name`, else `$USER`), path printed. With
  none free it grows the pool or exits 3 at `pool_max`, as `claim` does; a bad option exits 2.
  `claim`, `sweep`, `health` (no fast-forward or move of a free worktree, no empty-claim release)
  and the `next` job pass over it; `release <path>` frees it as any claim.
  `pool` and `board` show it as reserved by that name.
- `steward.sh sweep` says `<item>: cleared the merge gate` when it clears one, so the console's
  Sweep button and the job logs show which gates went with the worktrees.
- `steward.sh claim` and `reserve` allocate under one claim lock (`<flow home>/claim.lock`), so a
  claim from the worktree hook or by hand and a reserve running together never take the same
  worktree. Each exits 75 when another allocation holds the lock past the lock wait.

## 1.27.1 (2026-11-01)

- The `implementer` brief: moved code is touched code (U-05), and a test the implementer adds or
  changes meets the test writer's pre-commit checks. Four T-09 blockers landed on tests written
  in implement commits, outside the test writer's split check.
- The `test-writer` brief: a test must not pass on nothing. No `?.` ahead of an assertion, and
  a not-empty check before comparing two recordings or collections (T-01).

## 1.27.0 (2026-11-01)

- `comments.sh request-review <pr> <ask> [reviewer]` asks one reviewer when a name is given: one
  in `reviews.reviewers` or any GitHub login, with or without its `@`, checked like the list's
  names. It is the same mention comment with the same request marker, Copilot through the
  reviewers API, so the health job tracks and chases it. Console 0.10.0's PR cards use it.

## 1.26.0 (2026-10-31)

- Named schedules: one job can run on several schedules, each with its own args.
  `jobs.schedule.<name>` takes a job (`next`) or a job, a dash and a label of a lowercase letter
  then lowercase letters and digits (`next-codex`, `next-gh81`). Each schedule has its own launchd
  agent (`com.<repo>.flow.<name>`), log, lock, pause, history and `runs.jsonl` name; the job
  learns it from `--as <name>`, which the agent's command passes. A named `next` schedule's workers
  are `<name>-<n>`. Two `next` schedules no longer skip each other on one lock, and the pick lock
  still keeps them off the same item. `jobs.workers` stays the plain `next` schedule's: a named
  one runs `--workers N` from its args, or one worker. The schedules of any other job share its
  state (intake's notes and ledger, the PR replies, the lessons, the claims), so they take turns on
  `<job>.shared.lock`: a run that finds another schedule of its job alive skips.
- A schedule's args may begin with `claude` or `codex`: that schedule runs on that host instead
  of `jobs.host` (`every 30m codex --max-steps 15`). Another plain word there is refused as a
  misspelled host; item ids and options are args as before. An arg may hold a `#`, so a GitHub
  item id (`gh#12`) can be one, but not as its first character, which YAML reads as a comment.
- `jobs.sh` takes a schedule name in every command, and `all` covers every schedule the config
  names. `install` refuses a bad schedule name, exit 2. `status --json` gives each row `name`,
  `job` (the script it runs), `host`, and `configured`: false for a schedule installed here that
  the config no longer names, which `status` lists and `uninstall <name>` removes.
- `steward.sh stop <item>` ends an item's run (the process its record names and every session
  under it), removes the record so the health job does not resume it, and keeps the claim, the
  worktree and its changes. It writes a `stopped` line to `events.log` and the item's
  `last_event`. Nothing running is said, exit 0; a malformed item exits 2.
- `steward.sh resume <item> [--host H] [--wait]` starts a run whose process is gone again, as the
  health job does: the same note in the step's brief, the same `jobs.health.max_resumes` count,
  then the escalation gate (exit 4). A live run or no record is refused, exit 1. Its
  `events.log` lines are of the kind `resume`.
- The health job's streaks of `next` runs that did no work count the named schedules' runs too.
- Every job takes `--model <name>` and `--effort <level>`, so each schedule can run on its own
  pair (`jobs.schedule.intake: daily 02:00 codex --effort low`). They replace
  `jobs.<host>.model` and `jobs.<host>.effort` for that run only: next for its steps with no
  agent (on the host argument's run or workers), comments, intake and retro for their sessions,
  health for the run it resumes. `run-unattended.sh` takes them too. An effort the host does not take fails the run
  at its start, exit 2, recorded in `runs.jsonl`. A run or schedule with its own `--effort` never
  checks the pair's, which it replaces. `steward.sh health` and `steward.sh resume`
  take them too.

## 1.25.0 (2026-10-31)

- A gate can send the work back. `gate.sh clear <item> --back "<what to change>"` runs the step
  that raised the gate again, with attempts at 0 and the owner's note in its brief, instead of
  continuing past it. A note is required. `gate.sh raise` takes the step to go back to as a
  fourth argument and keeps it as `gate_from`; a feel test goes back to the step that wrote the
  code. A gate raised before 1.25.0 has no `gate_from` and says so.
- Gate messages lead with the decision, in bold: each gate's `asks` in `profiles.json` (for
  example "Approve the plan, approve it with notes, or send it back."), then the step's summary.
  The brief asks agents for a markdown summary and a gate message that starts with a bold ask.
- Every answer adds one `answered` line to `events.log`: the gate and the answer, or where it
  was sent back to. The console lists them as "Answered today".
- The local adapter keeps `gate_from` in an item's state.

## 1.24.0 (2026-10-31)

- A free worktree sits on its own idle branch, `<base>-wt-<n>` (`main-wt-2` for `../app-wt-2`),
  not on a detached head. Git checks a branch out in one worktree only, so each worktree gets
  its own. `release` and a new pool worktree put it there at the base's tip. The health job
  moves a free worktree it finds detached onto it, fast-forwards one already on it, and says,
  without moving it, one that sits on any other branch. An idle branch with commits the base
  does not have is kept: the worktree stays detached and that is said.
- At the merge gate the health job reads the PR's review. A PR with changes requested, a
  reviewer GitHub still lists as requested, or a flow reviewer (codex, claude) yet to answer is
  in review: it is not waiting at the merge gate, gets no merge reminder, and the summary counts
  it `N in review`. The approval a repository requires is the owner's and does not hold it.
  The verdict goes to `.flow/reviews/<n>.review.json` for the console, and goes when the gate
  does.
- A reviewer that replies it cannot review ("To use Codex here, create an environment for this
  repo") is told to the owner once, as a health notification: who, what it said, and that the
  PR waits at the merge gate without that review. `comments.sh reviews` carries the reply's
  first line as `cannot`; the reply still answers, so it is not chased.
- `comments.sh state` adds `reviewDecision`, `latestReviews` and `reviewRequests`.
- `steward.sh sweep --item <id>` looks at that item's worktree only, and `--lock` takes the
  sweep lock without waiting and exits 75 when it is held. The console (0.7.5) runs
  `sweep --lock --item` once it sees a gated PR leave the open list, so the merge gate clears
  within a minute of the merge, not at the next `next` or `health` run. The console also keeps
  a PR in review off its merge gate, by GitHub's review state and the health job's record.
- The health job counts a Copilot review as waiting only while GitHub lists the request. Before,
  a request the owner removed still held the PR in review, because the timeline does not show a
  removal. Codex and Claude, asked by mention, still count from the comments.

## 1.23.0 (2026-10-30)

- `jobs.workers` in `.flow/config.yaml` splits the `next` job's workers across hosts:
  `{claude: 1, codex: 2}`, or one host per line under it. A scheduled `next` run with no
  `--workers` starts each worker on its own host, numbered across the hosts, claude first:
  `next-1` on claude, `next-2` and `next-3` on codex. `jobs.sh status` lists each worker under
  the table with its host, and `status --json` gives the next row a `workers` list (job, host,
  running, last_run). `--workers N` given by hand still starts N on the host named. A host other
  than claude or codex, or a count that is not a whole number, stops the run (exit 2, recorded
  so `status` shows it), and `run` and `install` refuse it, as they refuse `jobs.workers` beside
  `--workers` in `jobs.schedule.next` (#65, point 1).
- Pausing `next` pauses every worker of it. A worker started by hand with a label that is not a
  number (`--worker codex`) looked for its own pause file, so it ran through a pause, and
  `status` never showed it. `--worker` now takes only a number, and a worker's pause is its
  job's, whatever its label (#65, point 10).
- An unset `reviews.chase_after` is the 1h default, silently. The default was applied with
  `sed`, which never sees a line when the key is missing, so every chase stopped with
  `reviews.chase_after is ''` (#65, point 6).
- The comments job skips an item whose worktree another session works in, named or not, found
  as the health job finds a live run: `<item>: another session works in <worktree>
  (process N), skipped`. A list of processes that cannot be read counts every worktree as in use
  (#34). A PR number finds its item from a local item's branch (`flow/local-task-1`) as well as
  from `flow/gh-<n>`, so the check, and the resume note, cover local items too.
- A cleared gate is new activity for the comments job. `gate.sh clear` records `answered_at` in
  the item's state, and the job's activity line carries it, so a PR whose pass stopped at a gate
  is picked up once the owner answers, without a run by hand. A line from before keeps its form,
  so an upgrade starts no pass (#65, point 7; #34).
- `jobs.sh status --json` keeps the runs a pause or a live lock ended at once. `last` is still
  the newest run that did something. `last_run` is the newest run of any kind and `latest` the
  newest of each outcome, each with `reason` (the live run a skip found, the pause, the error).
  Each line of `runs.jsonl`, each running entry and each worker carries the `host` it ran on.
- Each `runs.jsonl` line is one write. Workers that ended together could interleave a line and
  its newline, so two runs shared a line that no reader could parse.

## 1.22.0 (2026-10-30)

Spend control for unattended runs (#65).

- A step with no agent (design, implement, review, explain) runs on the jobs' pair for the
  host, `jobs.<host>.model` and `jobs.<host>.effort` in `.flow/config.yaml`, on claude and on
  codex. Before, it ran on the host's own default model and effort, whatever the config said.
  Steps with an agent still take the roster's pair. `run-unattended.sh` and the `next` job
  check the pair before they claim a step, so a bad effort stops the run, not the session.
- The architect runs only for L tasks and epics. `profiles.json` has an `architect` switch per
  profile; the design step's brief says `Architect: yes` or `no`, and on no the step ends with
  the exploration and the planner designs from it.
- Claude sessions use the 5-minute prompt cache. A subscription defaults to one hour, which
  costs more to write (2x the input price, against 1.25x) and pays off only when a session
  idles more than five minutes between turns; a step session does not.
  `host_run` sets `CLAUDE_CODE_PROMPT_CACHE_TTL` and `CLAUDE_CODE_SUBAGENT_PROMPT_CACHE_TTL` to
  `5m` unless the owner set them.
- Each unattended step session is a line in `<flow home>/log/runs.jsonl`: the item, the step,
  the host, the model, the effort, the seconds, the exit, the tokens and the cost where the host
  reports it (claude does, codex reports tokens only). Claude runs with `--output-format json`
  and codex with `--json`; `scripts/_host.py` reads the usage and passes the text on to the
  log. A step line has no `job` key, so the job readers skip it.
- The board has a spend section: cost, sessions and tokens per item, summed over its step
  sessions.
- A session that fails on a spend limit or an auth error stops the host. The run raises the
  escalation gate on its item, naming the cause and the host's own words, and exits 4. No
  session starts on that host, from any loop or job, until the owner clears the gate, or
  `gate.sh clear <claude|codex>` for a stop outside an item's run. `gate.sh list` shows a
  stopped host. Before, the loop went on to the next step and failed the same way on each one.

## 1.21.1 (2026-10-28)

- The launchd agent `jobs.sh install` writes sets `AbandonProcessGroup`. Since 1.20.8 a `next`
  run with `--workers` starts its workers and exits, and launchd ended every process the run
  had started when it did, even workers in their own session. On foosbrawl no scheduled worker
  ran for about nine hours; each one logged a SIGTERM within seconds of starting. Reinstall the
  jobs (`jobs.sh install`) to pick it up: `jobs.sh status` shows `reinstall: jobs.sh install
  <job>` as the next run of every agent installed before.
- A detached worker no longer leaves an idle shell waiting behind it.

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
