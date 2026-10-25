# Brain Console

The control plane for the flow: one local daemon that watches every flow project on this
machine and serves a reconciled, live snapshot. The UI, a tray, a chat pane and an MCP server all
read that one shape. Node 24, TypeScript run as-is, no runtime dependencies.

## Run it
```bash
cd app && npm install
npm start -- --project /work/projects/foosbrawl            # one or more --project flags
curl -s http://127.0.0.1:7474/api/projects/foosbrawl/snapshot | jq .counts
curl -N http://127.0.0.1:7474/api/projects/foosbrawl/events  # server-sent events, one snapshot per change
```
To try a flow plugin that is not installed, such as a checkout of this repository, start with
`FLOW_PLUGIN=/path/to/brain/plugins/flow`: every flow script the daemon runs gets it, and the
version shown comes from that plugin's own `plugin.json`.
`--config <file>` reads and writes the settings (below) in that file instead of
`~/.config/brain-console/config.json`, and looks for the old `projects.json` beside it, so a second
daemon for a trial (`--port 7477 --state-dir /tmp/console-test --config /tmp/console-test/config.json`)
never touches the owner's settings. Ctrl+C stops it, open console tabs or not: streams are cut, running actions get SIGTERM, and a
second Ctrl+C ends the process at once. Projects also come from `BRAIN_CONSOLE_PROJECTS` (colon separated roots) or
the settings file (below). Every root must hold a `.flow/config.yaml`, or the daemon refuses to start. It binds `127.0.0.1` only and every route needs
the token, as `Authorization: Bearer <t>` or `?token=<t>`: `--token <t>` or `BRAIN_CONSOLE_TOKEN`,
else the one the daemon makes on first start and keeps in `~/.local/state/brain-console/token`.
Started from a terminal, the daemon prints the URL with the token in it to that terminal; the
structured log line names only the token file, so the token never lands in a log. The state dir is
kept `0700` and the token file `0600`. A request whose `Host` is not a loopback
name, or whose `Origin` is not a local page, gets 403, so a page on another site cannot drive
the console even from the owner's own browser.

## Run it on login
```bash
cd app
npm run daemon:install -- --project /work/projects/foosbrawl   # the same flags as npm start
npm run daemon:status                                          # loaded or not, the pid and the URL
npm run daemon:uninstall                                       # stop it and remove the agent
```
`install` checks the flags as a start would, then writes
`~/Library/LaunchAgents/com.brain.console.plist`: the absolute `node` and `daemon/src/main.ts`,
the flags with every path made absolute, `RunAtLoad` and `KeepAlive`, `PATH`, `HOME`,
`BRAIN_CONSOLE_LAUNCHD=1` (and `FLOW_PLUGIN`, `BRAIN_CONSOLE_PROJECTS`, `BRAIN_CONSOLE_STATE` when
set) in `EnvironmentVariables`, `Umask` 63 (077, so the log is the owner's alone), and stdout and
stderr to `<state dir>/daemon.log`; the state dir is closed to `0700`. It takes no `--token`: the
plist would keep the secret, so the daemon reads `<state dir>/token`. After booting a loaded job
out it refuses when something else holds the port and names it (`lsof`), such as an `npm start`
daemon; then it loads the plist with `launchctl bootstrap gui/$UID <plist>` (falling back to
`launchctl load -w` when bootstrap fails), waits up to 15 s for the port, asks
`launchctl print gui/$UID/com.brain.console` for the job's pid and reports it, and prints the URL
with the token to the terminal. `KeepAlive` starts a daemon that exits again about every ten
seconds, a bad config among the causes; such a daemon says in the log why it cannot start and that
launchd will keep trying until it is fixed or `npm run daemon:uninstall` stops it. `uninstall` runs `launchctl bootout gui/$UID/com.brain.console` and removes the plist.
`status` says whether launchd has the job and prints the URL from the plist's flags. Settings says
whether the daemon runs under launchd. The scripts are `daemon:*`, not `install`: npm runs a
script named `install` on every `npm install`.

## Settings
`~/.config/brain-console/config.json` holds the settings, every field optional:

```json
{ "projects": [{ "root": "/work/projects/foosbrawl" }], "terminal": "iterm", "port": 7474 }
```

- `projects`: the roots to watch, absolute (or starting `~/`). Precedence is `--project` flags,
  then `BRAIN_CONSOLE_PROJECTS`, then the file; projects set by a flag or the environment show in
  Settings but cannot change there, with the note why.
- `terminal`: what Open in Terminal opens, `"iterm"`, `"terminal"`, `"ghostty"` or
  `{"command": ["open", "-a", "Warp", "{path}"]}`, run without a shell. In each word `{path}` is
  the folder as it is (for a word of its own), `{qpath}` the folder quoted for sh and `{cmd}` the
  command to run there (a job's log), quoted already: inside an `sh -c` string use `{qpath}` and
  `{cmd}`, never `{path}`, or a folder with `$(…)` in its name would run. With neither path the
  folder is added last. The Settings screen takes the command as a JSON array, so a word may hold a
  space. Unset, the console takes the first installed of
  iTerm, Ghostty and Terminal (an app in `/Applications` or `~/Applications`, Terminal also in
  `/System/Applications/Utilities`).
- `port`: the port to listen on when no `--port` is given (7474 by default). It takes a restart,
  and while `--port` sets the port a saved one has no effect at all; the note in Settings says so.

While `config.json` is absent the daemon still reads the projects of the older
`~/.config/brain-console/projects.json` (`{"projects":[{"root":"…"}]}`); the first save from
Settings writes `config.json` with them, and `projects.json` is then no longer read. A file that is
not valid JSON, or holds a setting the daemon does not know, stops the daemon at start with the reason.

`PUT /api/settings` (the Settings screen) changes the settings its body names and keeps the rest:
the whole body is checked first (every root holds `.flow/config.yaml`, no two share a folder name,
at least one stays, the terminal is a name or a non-empty command, `"terminal": null` goes back to
the first installed), then merged into the file as it is on disk at that moment (a hand edit made
while the daemon runs is kept; a file that no longer parses is refused with the reason, never
overwritten), written in one step and applied. A changed project list
applies at once: a new root gets its monitor started, a removed one is stopped and dropped (its
attached actions get SIGTERM), and every open event stream carries `event: projects` with the new
list. A stream whose project was removed, or whose id now names another root, ends after that list.
The terminal counts from the next Open in Terminal; the port only after a restart.

## Routes
| Route | What |
|---|---|
| `GET /healthz` | `{ok, projects}` |
| `GET /api/projects` | every project with its counts |
| `GET /api/settings` | the effective settings, each with `from` (`flag`, `environment`, `file`, `default`): the projects (and whether they can change here), the terminal and the installed ones, the port, the config file, the state folder and whether launchd runs the daemon |
| `PUT /api/settings` | change settings, body `{"projects"?, "terminal"?, "port"?}` as JSON; 200 with the new settings, 400 with the reason |
| `GET /api/projects/<id>/plugins/flow/config` | the project's `.flow/config.yaml` for the editor: `{path, text, hash, values, sections, warnings}` (below) |
| `PUT /api/projects/<id>/plugins/flow/config` | change it, body `{"changes": [{"path", "value"}], "hash", "force"?}` or `{"text", "hash", "force"?}`; 200 with the new document plus `saved` and `followUps`, 400 with the reason, 409 with `reason: "stale"` or `"dirty"` |
| `GET /api/projects/<id>/snapshot` | the current snapshot |
| `GET /api/projects/<id>/agents/<pid>/transcript?lines=<n>` | `{session, turns: [{at, role, text}]}`: the last `n` turns with text (default 20, at most 200) of the claude transcript of an agent or session in `agents` or `ended`, oldest first; user and assistant lines, their `message.content` text parts, without meta lines, side chains, tool calls or tool results; read from the last 4 MB of the file. 404 for a pid not listed or without a transcript, 400 for a codex session or a bad `lines` |
| `GET /api/projects/<id>/events` | SSE stream: `event: snapshot` on every change, `event: action` on every action update, `event: projects` (the project list) when Settings change it, a heartbeat every 15s; the stream of a removed project ends after that list |
| `GET /api/projects/<id>/events?item=<id>&limit=<n>` | the kept events as JSON instead, `{events, total, kept}`: newest first, only `item`'s when given, at most `limit` (default and cap 200); `total` is how many of the kept 200 matched before the limit, not every event the project ever logged. URL-encode the item (`item=gh%23213`: a bare `#` starts the fragment and never reaches the daemon). Any of `item`, `limit` or `Accept: application/json` asks for JSON; a bad limit is 400, any method but GET 405 |
| `POST /api/projects/<id>/refresh?source=<files\|git\|processes\|jobs\|board\|pulls>` | re-read one source now (all when omitted) |
| `POST /api/projects/<id>/actions` | run one action, body `{"kind","args"}`; 202 with the record, 400 on a bad request, 409 when its lock is held |
| `GET /api/projects/<id>/actions` | the recent 50 actions, newest first, with the output tail |
| `GET /api/projects/<id>/actions/<actionId>` | one action with its full output |

## The snapshot
`daemon/src/snapshot.ts` is the contract; `schema` is its version, 2 since processes carry their
session. One `Snapshot` per project: `project`, `sources`
(when each source was read and whether it worked), `counts`, `readiness`, `attention` (what needs
a human, oldest first), `worktrees`, `items`, `gates`, `runs`, `agents`, `ended`, `jobs`, `pulls`, `events`
(the latest 200, each with `at`, `item`, `kind` and `message`) and `disagreements`. Timestamps are
ISO UTC; every age is seconds at `takenAt`, so a reader keeps counting on its own clock between
snapshots.

- `project`: `id`, `name`, `root`, `flowHome`, `base` (the branch work merges into), `repo`
  (`github.repo`), `repoUrl` (`https://github.com/<repo>`, null without a repo), `trackerUrl` (the
  issues page on the github adapter, null on local), `adapter`, `pluginVersion`, `pluginRoot`
  (the plugin's folder), `pluginSource` (`FLOW_PLUGIN` when the daemon was started with that
  variable, `installed` when `.flow/plugin.sh` found it in the plugin cache, null with no plugin),
  `jobsHost` (`jobs.host`, the CLI the jobs run) and `poolMax`.
- A worktree carries `agents` and `sessions`, each a list of `{pid, host, command, elapsedSeconds,
  session}` (the command cut to 200 characters), `item`, `itemUrl` and `itemTitle` (from the board, null
  without an item or before the board is read), and `staleReason`: "branch is 35 commits behind
  main (limit 20)", "claimed 6 days ago with no run, agent or gate", both joined with "; ", or null.
- `session` (on those and on every entry of `agents`) is the process's transcript,
  `{host, id, transcript, resume}`, or null when none was found. For claude it is the newest
  `*.jsonl` in `~/.claude/projects/<cwd with every character but letters and digits made "-">/`
  written at or after the process started (now minus its elapsed time, with two seconds for ps's
  rounding); the id is the file name. For codex `~/.codex/session_index.jsonl` has ids and thread
  names but no folder, so the session files under `~/.codex/sessions/<yyyy>/<mm>/<dd>/` (the
  start's day back to fourteen days) are read instead: the newest written since the start whose
  first line, `session_meta`, names the same cwd; the id is its `payload.id`. `resume` is the argv
  that opens it again: `["claude", "--resume", id]` or `["codex", "resume", id]`. The home folder
  and the clock are injected (`daemon/src/collectors/sessions.ts`).
- `ended` lists the agents and sessions with a session that left the process list while the
  daemon watched, in the last 24 hours, at most 10, newest first: an `agents` entry plus `endedAt`
  (when the read that missed it ran). It lives in the daemon's memory, so a restart empties it.
- An item's `url` is its tracker page, from the board.
- A gate carries `pull`: `{number, url, state, unresolvedThreads}` for its item's open PR (the one
  its `pr` field names, else the one on its claimed branch, whatever order GitHub lists them in),
  or null. A merge gate whose PR still
  has an unresolved thread shows it there.
- `readiness` is `{ready, waitingOnField, blocked, gated, nextInLineMissingField}` over open
  items that are not epics. The first four are buckets, each item in one at most: the next job can
  take it, only an empty field stops it (the whole backlog of such items), an open item blocks it,
  it waits at a gate. Running, claimed and stale items count in none, so the Overview can say in
  one line why nothing runs. `nextInLineMissingField` is the part of `waitingOnField` that is the
  next step of work already under way, so the UI can say "164 backlog items lack a field; 4 of
  them are the next step of work in progress".
- A `needs-field` attention row (and `counts.needsField`, equal to `nextInLineMissingField`) is
  kept for those next-in-line items only: open, not an epic, no step, no open blocker, a `needs`
  that is not empty (a field `ready_needs` asks for, such as priority or size, is empty, so the
  next job refuses it), and either its parent has started (a step, a worktree, a PR or a gate), a
  sibling under the same parent has started or is done, or it blocks an item that has started.
  Every other item waiting on a field is backlog and gets no row. The row's `detail` names the
  fields: "needs priority", "needs priority and size".

One status language, used by worktrees and items alike:

| State | Meaning |
|---|---|
| `running` | an unattended agent process (`claude -p`, `codex exec`) has its cwd in the worktree, or a live run record |
| `needs-you` | its item has a gate record in `.flow/gates` |
| `stale` | the branch is ≥ 20 commits behind its base, or the claim is ≥ 72h old with no run, agent or gate |
| `claimed` | claimed, idle, nothing waits on you |
| `free` | no claim |
| `outside` | the main worktree or one not in the pool |

Flags add detail without changing the state:

| Flag | Meaning |
|---|---|
| `dirty` | the worktree has uncommitted files, changed or untracked |
| `behind` | its branch is at least one commit behind the base |
| `stale-branch` | a claimed branch is 20 or more commits behind the base, so it needs the base merged in |
| `idle` | claimed for 72h or more with no run, no agent and no gate |
| `dead-run` | a run record names it but no agent process is in it |
| `agent-without-claim` | an unattended agent works in a pool worktree nobody claimed |
| `session` | an interactive session is open in the folder (see below) |

Every open pull request carries one state, the first that holds:

| PR state | Meaning |
|---|---|
| `draft` | a draft PR |
| `conflicts` | GitHub says it does not merge cleanly (`mergeable` `CONFLICTING` or merge state `DIRTY`) |
| `checks-failing` | a check failed: each check counted once, by its latest run (a queued re-run is the latest); a completed run counts as failed unless it ended `SUCCESS`, `NEUTRAL` or `SKIPPED` |
| `changes-requested` | the review decision is `CHANGES_REQUESTED`, or, with no review required, a latest review asks for changes |
| `checks-pending` | a check is still queued or running |
| `review-pending` | the repository requires an approval and has none yet |
| `approved` | approval is satisfied (approved, or no review required) but a review thread is unresolved, or GitHub does not let it merge yet (merge state `BLOCKED`, `BEHIND`, `UNKNOWN`, or `mergeable` not `MERGEABLE`) |
| `mergeable` | checks green, approval satisfied, no unresolved thread, `MERGEABLE`, merge state `CLEAN`, `HAS_HOOKS` or `UNSTABLE`: ready to merge |

A PR belongs to the item whose `pr` field names it (a number, or its URL compared without case or
scheme), else to the item claimed on its head branch unless the PR comes from a fork, and that
gives its worktree. `checks-failing`, `changes-requested` and `mergeable` each add an attention row
(`pr-failing`, `pr-changes-requested`, `pr-mergeable`), and `counts` carries `pullsFailing`,
`pullsChangesRequested` and `pullsMergeable`.

## Sources and cadence
| Source | How | Every |
|---|---|---|
| `files` | `.flow/config.yaml`, `gates/*.json`, `runs/*.json`, each pool worktree's `.flow/claim.json`, `events.log`, the plugin `.flow/plugin.sh` resolves, and `gate.sh list --json` for the questions of a gate whose message it has not parsed yet¹ | 30s, and at once on any change under `.flow` |
| `git` | `git worktree list`, per worktree ahead/behind the base, dirty files, last commit | 30s, and after a file change |
| `processes` | `ps` + `lsof` for `claude`/`codex` processes and their cwd. The program is the first word of the command, joined across a space only while the path runs on inside an `.app/` bundle or `Application Support/` (where the Claude desktop app keeps its CLI), so `sh /usr/local/bin/claude` or `node …/claude` is the wrapper, not the host. A host's own servers never count, named by the first two words after the program that are not options (`claude daemon run`, the Codex desktop app's `codex app-server --listen unix://…`, `codex app-server daemon pid-update-loop`, `codex -c … exec-server`), so a prompt that mentions a daemon is still an agent | 10s |
| `jobs` | `scripts/jobs.sh status --json` from the project's flow plugin | 60s |
| `board` | `scripts/board.sh --json` (asks the tracker; tens of seconds on GitHub) | 120s |
| `pulls` | `gh pr list` for the open PRs of `github.repo`, then one `gh api graphql` for their unresolved review threads (the first 100 per PR); a project not on the github adapter, or without `github.repo`, reports `ok` with `error: "not applicable: …"` and is never read | 60s |

¹ Flow 1.18.0 and later. The parse is kept per gate until its message changes, so a waiting gate
costs no process after its first read. An older plugin is not asked. A list that fails, times out
(10s) or prints no JSON leaves the gate in place with the daemon's own parse, puts the reason on the
`files` source (`ok` stays true) and logs `gates.list.failed` once. A message with no numbered line
gets no questions from the plugin and shows as one question with no recommendation.

The daemon itself never writes to a project but in one place, the flow settings editor below,
which writes `.flow/config.yaml` when the owner saves. Every other write goes through an action.

## Flow settings
`daemon/src/plugins/flow/` edits the project's `.flow/config.yaml`. `schema.ts` is a fixed schema
of every key the flow plugin reads (its scripts, `skills/init/SKILL.md` and the foosbrawl file):
the dotted path, the type (`string`, `number` with a range where one is known, `boolean`, `enum`
with its values, `list` of text, `map` of name to text, `duration` like `1h`, `schedule` like
`every 30m --workers 2`, `daily 02:00` or `weekly sun 07:00` with the args `jobs.sh` takes), one
sentence on what changing it does, its group (Tracker, Readiness, Worktree pool, Gates and
verification, Reviews, Notifications, Jobs, Intake) and its follow-up: `jobs.schedule.*` and
`jobs.host` need `jobs.sh install` to reload the schedule launchd runs (the `jobs.install` action);
the pool keys (`pool`, `pool_max`, `worktree_copy`, `worktree_setup`) count at the next claim.

`GET` reads the file. `values` is the file as the existing parser (`daemon/src/yaml.ts`) reads it,
but only after `configDocument.ts` has checked that every line is in the flat format the file's
header names (two-space indentation, `key: value`, nested maps, `- item` or `[a, b]`); a tab, an
anchor or alias, a tag, a multi-line string, a flow map, a list of maps or a key set twice makes
`values` null with the line in `warnings`, and only Raw YAML can change it. `sections` is the
schema's groups in order plus, when the file has keys the schema does not know, an `Other` group
of them as text (or a list of text). A known key whose value does not fit its type is a warning.
`hash` is the sha256 of `text`.

`PUT` checks first and writes last. Each change is checked against its key's type, enum and range
(an unknown key takes text, or a list of text; `null` takes a key out). The text is then rewritten
in place: a known key changes only the value on its line (its trailing comment kept), a list only
its item lines (an inline list stays inline), a map only its children's lines; a key not in the
file goes under its section's last line, or at the end of the file; every comment, blank line and
key order stays. A value holding ` #` is refused, since `lib/flow.sh` reads a comment there even in
quotes. The result must parse again and read back to the values sent, or nothing is written. `{text}`
saves the whole file, held to the same format and types. It is refused (409) when the file's hash is
not the one sent (it changed on disk since the GET, force or not), and when
`git status --porcelain -- .flow/config.yaml` lists it (uncommitted changes, or untracked) unless
the body says `"force": true`. After a write the `files` source is read again before the reply,
the daemon logs one `flow.config.saved` line with the keys that changed, and the reply carries
`saved` (the leaf keys whose value changed) and `followUps` (`{note, action, paths}`).

## Actions
An action is one flow script, run by path with argv and never through a shell, with every
argument checked against a shape first. The event stream carries `event: action` with the record
on every state change and at most twice a second while output arrives.

| Kind | Args | Runs | Lock | Outcome when done |
|---|---|---|---|---|
| `gate.clear` | `item`, `message?` | `gate.sh clear <item> [<message>]` | the item | `finished` |
| `run.start` | `item?`, `maxSteps?` | `jobs/next.sh <jobs.host> <item> --max-steps N`, detached; without an item `jobs.sh run next` | the item and the next job | with an item `started` while the run goes, `finished` once it ends well; without one `started` |
| `job.run` | `job` | `jobs.sh run <job>` | the job | `started` |
| `job.stop` `job.pause` `job.resume` | `job` | `jobs.sh <verb> <job>` | the job | `finished` |
| `worktree.claim` | `item` | `steward.sh claim <item>` | the pool and the item | `finished` |
| `worktree.release` | `target`, `force?` | `steward.sh release <item or pool path> [--force]` | the pool and the item or worktree | `finished` |
| `worktree.sync` | `target` | `daemon/scripts/sync.sh <worktree> <base>` (below) | the item and the worktree | `finished` |
| `steward.health` | | `jobs.sh run health`, so the health job's own lock applies | the health job | `started` |
| `jobs.install` | | `jobs.sh install`: writes and loads the schedule of every job `jobs.schedule` names | every job (`job:next`, `job:comments`, `job:intake`, `job:retro`, `job:health`) | `finished`; `jobs` is re-read |
| `pr.merge` | `pr`, `method?` (squash) | `gh pr merge <pr> --repo <repo> --<method> --delete-branch` | the PR | `finished` |
| `terminal.open` | `path`, `job?`, `session?` | a terminal window in `path` (below); with `session` (a pid) one with that process's resume command | none | `finished` |
| `refresh` | `source?` | re-reads the sources in the daemon | none | `finished` |

`ActionRecord.outcome` says what a successful action did: `started` means the work was handed on
and goes on after the record (`jobs.sh run <job>` gives the job to launchd and returns in a
second), `finished` means the work is over. It is null while an attached action runs and on a
failed or rejected one. Every `jobs.sh run <job>` (`job.run`, `steward.health`, `run.start` without
an item) also re-reads its sources a second time five seconds after it returns
(`ActionPlan.refreshAgainMs`), so the run it started shows; a daemon that stops drops the wait.

`worktree.sync` brings a claimed pool worktree up to date. The target is an item or a pool
worktree's name, as for a release; the base is the claim's, else the project's. It is refused, each
with its own reason, while the worktree has uncommitted files, a run record in `.flow/runs` names
its item, or an unattended agent works in it. The script runs `git -C <worktree> fetch origin`,
merges the branch's own upstream when that is ahead, then `origin/<base>` when it exists (else the
local base), each with `merge --no-edit`; the output names every merge. A merge that conflicts is
undone with `git merge --abort` and the action fails with the conflicting files in its output.
A TERM or INT (a timeout, a removed project, the daemon stopping) mid-merge aborts the merge too,
so no `MERGE_HEAD` is left behind, and the script exits 143. When it ends `git` is read again.

`terminal.open` opens only the project root, a pool worktree from `.flow/config.yaml`, another
worktree git lists for the project (the outside rows), or the working directory of an agent or
session the snapshot lists (so only processes in this project's worktrees); any other path is refused with the
reason. The app is the `terminal` setting, else the first installed of iTerm, Ghostty, Terminal:
`iterm` runs `open -a iTerm <path>`, `terminal` `open -a Terminal <path>`, `ghostty`
`open -na Ghostty --args --working-directory=<path>`, a custom command its words with `{path}`,
`{qpath}` replaced. With `job` (from the root only) the window follows `<root>/.flow/log/<job>.log`, the file
`jobs.sh logs` reads, with `tail -n 200 -f`: iTerm through `osascript` (`create window with default
profile command`, the line handed to `/bin/sh -c`), Terminal through `osascript` (`do script`),
Ghostty with the line as the one word after `-e` (assumed to work whether Ghostty runs that word
through a shell or joins its `-e` words into one shell string; not tried on every version), a custom command with `{cmd}` replaced by the line. The line is
`cd <path> && tail -n 200 -f <log>` with every word quoted for sh and then for AppleScript, so a
path with a space or a quote stays one word. Nothing is locked or re-read.

With `session` (the pid of an agent or session in `agents` or `ended` whose transcript was found;
`job` with it is refused) the window opens in the folder that process ran in (`path` must be it:
`claude --resume` finds a session by its folder) with its resume command. A running `claude -p`
or `codex exec` cannot be attached to, and a second writer on its session would mix with it, so
while the process is alive the command waits for the owner: iTerm types it without pressing Enter
(`write text "<cmd>" newline NO` after `write text "cd <path>"`, through `osascript`); Terminal
cannot type without running, so `do script` prints it (`echo`) and leaves the shell; Ghostty does
the same with the line after `-e`, then `exec "${SHELL:-/bin/sh}" -l` keeps a shell; a custom
command gets that line in `{cmd}`. Once the process has ended the command runs at once in all of
them.

An item is `gh#12` or `local:task/7`; a release target is an item or the name of a pool worktree,
which the daemon turns into its path. An argument the kind does not take is refused, so a typo
never changes what runs. A second action on a held lock is refused with 409 and recorded as
`rejected`. At most four run at once. Scripts get two minutes, a merge three; a process that
ignores SIGTERM is killed with its group ten seconds later, and a timed-out action is `failed`
whatever its exit code. A run started with `run.start` and an item is detached, writes its own output file,
holds its item for as long as it runs and is never killed by the console. `jobs/next.sh` takes
the next job's lock, so a console run while the scheduled job is busy prints "skipped" and ends
at once. When an action ends the sources it changed are re-read.

Every action is two lines in `~/.local/state/brain-console/<project>/actions.jsonl`, one at
start and one at the end, with its full output in `actions/<id>.log` beside it (`--state-dir`
or `BRAIN_CONSOLE_STATE` moves it). Nothing is written inside the project except what the
scripts themselves write.

## Reconciliation
`daemon/src/reconcile.ts` is a pure function from the collected facts to the snapshot, with the
clock injected. It derives states, ages, the attention list and the disagreements between the seven
places flow state lives (claims, gate records, run records, the process list, issue labels and
state, the project card, pull requests): a run record with no process, an agent in a worktree
without a claim, a claim whose step differs from the issue, a gate record the labels do not show,
and an open item at step done that waits on a merge with no merge gate. That last rule takes the
best evidence there is: with pull requests read, the item's PR is in state `mergeable`; when the
`pulls` source was never read or does not apply, the issue state naming a PR is enough.

The sources run on different clocks (files every 30s, the board every 120s), so a claim or gate
that just changed disagrees with the labels until the board is read again. That is lag, so a
disagreement enters the snapshot only when the same one (stores, item, worktree, message) is still
there after every store it names was read again by a read that started after it first appeared
(`daemon/src/settle.ts`); a read already in flight then may hold the old answer and does not
count, and neither does a read that failed. The claim, gate and run records come from `files`, the
process list from `processes`, issue state and labels from `board`, pull requests from `pulls`. A
real disagreement can therefore take up to one board cycle, about two minutes, to show. One that
goes away in between starts over. A source whose latest read failed does not hold a disagreement
back: it may show, and the source's red light on the strip says how far to trust it.

Every disagreement carries `explain`, one plain sentence saying what each store says and which is
usually right, and `action`, the button that settles it (`{kind, args, label}`) or null when a
person has to look:

| Stores | Usually right | Action |
|---|---|---|
| run record vs process list | the process list: the run ended or crashed | `steward.health`, "Run the health check" |
| process list vs claim | the process list: something runs there unclaimed | none |
| claim vs issue state (step or worktree) | the claim: the agent writes it first | none |
| gate record vs issue labels | the gate record: the labels catch up | `refresh` with `source: board`, "Re-read the board" |
| issue state vs pull request | the pull request: only the merge is left | `pr.merge` with the PR number, "Merge #N", only when the `pulls` source was read and that PR, open in `github.repo`, is `mergeable`; with pulls unread (not yet, failed, or not on GitHub) the row shows with no action, since nothing says the named PR is open, green or in this repository |

## What the words mean
| Word | Meaning |
|---|---|
| free | a pool worktree nobody has claimed; the next job may take it |
| claimed | a pool worktree holds an item (its `.flow/claim.json`), but nothing runs and nothing waits on you |
| running | an unattended agent works in the worktree, or a live run record says one does |
| needs-you | the item waits at a gate: a question only you can answer, or a merge only you can make |
| stale | claimed, but its branch is 20 or more commits behind the base, or nothing has happened in it for 72 hours; `staleReason` says which |
| outside | a worktree that is not in the pool: the main checkout or one git knows of elsewhere |
| dirty | the worktree has files that are not committed |
| agent | an unattended claude or codex the flow started (`claude -p`, `codex exec`) with its working directory in the worktree |
| session | an interactive claude or codex whose working directory is in the worktree, yours or an app's (such as the Claude desktop app), not an unattended agent; a host's own background server (the Codex desktop app's `app-server`) is neither |
| disagreement | two places flow state lives say different things, and kept saying it after both were read again |
| needs-field | an item that is the next step of work already under way (its parent or a sibling has started, or it blocks started work) but lacks a field the tracker asks for (`ready_needs`, such as priority), so the next job passes it over |

## The UI
`ui/` is Vite + React 18 + TypeScript, plain CSS with custom properties (light and dark follow
the system). It reads the daemon's types straight from `daemon/src/snapshot.ts` (type-only
imports). Six project screens, routed by hash (`#/<project>/<screen>/<detail>`), and Settings: Overview (five tiles, a
readiness line from `readiness` that says what runs, or why nothing does: how many items the next
job could take, how many next-in-line items lack a field and how many more in the backlog do, how
many wait at gates and how many are blocked; the needs-you table oldest first with the next-in-line
items that lack a field folded after five, the latest 30 events with Show
all, the disagreements with what each store says and the button that settles it, the 3x3 pool map
with each item's title, and the sources strip), Gates (a decision card per gate, one line on what
its kind asks, the PR with its state and unresolved review threads when the item has one, the
questions and recommendations as the plugin parses them on flow 1.18.0 and later, so the card
matches the Slack message, else the daemon's own parse, Answer runs `gate.clear`), Worktrees (the
pool, then the worktrees outside it under their own heading; each row has its item's title, its
agents and sessions with pid, host and age and the command on hover, why it is stale and the way
out (for a branch far behind, a "Merge <base> in" button that runs `worktree.sync` when the
worktree is clean, has no run record and no agent, else the same words without the button), a
legend for dirty, agents and sessions; Open in Terminal on every row, the project root
included, Release, Health), Agents and jobs (Open in Terminal on every agent and session row, in
its working directory; Run, Stop, Pause, Resume and Open in Terminal, which follows the job's log,
on every job; an agent or session whose transcript was found also gets Open session, which runs
`terminal.open` with its pid, titled "Opens a terminal at the worktree with the resume command
ready. The run is still going, so press Enter once it ends." while it runs, and a Transcript fold
under a claude row with its last 20 turns, read when opened and again with each snapshot; a table
"Ended in the last day" lists `ended` with Open session, titled "Opens a terminal at the worktree
and resumes the session.", Open in Terminal and the Transcript fold), Pull requests (from the `pulls` source, with Merge on a PR in state `mergeable`) and
Activity (`#/<project>/activity/<item>`: every kept event from `/events?limit=200`, narrowed to one
item with the filter box; a failed read shows a banner over the last events and is tried again every
10 s). A row above every screen holds the project's fields, each a small uppercase label over its
value: Project (the name; its title is the root), Repository (`owner/name`, linked), Tracker
("GitHub issues", linked to the issues page, on the github adapter; "local" on local), Base branch,
Flow plugin (the version; its title says whether it is the installed plugin or the one
`FLOW_PLUGIN` named, with its folder) and Jobs run on (`claude` or `codex`), with the Settings
link at the far right. At phone width the fields wrap. Settings (`#/settings`, linked from the top bar of every screen) lists the projects
with Add (a path) and Remove, or the note why they cannot change; the terminal as radio buttons
(the first installed, iTerm, Terminal, Ghostty, a custom command as a JSON array, checked as you type); the port, read
only, with the restart note; the config file, the state folder and whether the daemon runs under
launchd. A refused save shows the daemon's reason. Under the console's own settings, one section
per project, "flow settings for <project>", edits its `.flow/config.yaml`: the note "This edits
.flow/config.yaml in the project. It is a tracked file: commit it there.", the file's warnings,
then a form per schema group (each field labelled by its key, the control for its type: a select
for an enum or a boolean with "(not set)" to take the key out, a number or text box, a text area
of one item or `name: value` per line for a list or a map; the help under it) with its own Save,
disabled until something in the group changed. A save shows the keys written and each follow-up,
with a "Reload the schedule" button (`jobs.install`) when a schedule or `jobs.host` changed; a
refusal shows the reason, with Save anyway for a file with uncommitted changes and Reload for one
that changed on disk. A "Raw YAML" fold at the bottom holds the whole file in a text area with the
same Save (open when the file is not in the flat format). Every item id opens its tracker
page in a new tab; a link from the snapshot that is not `http` or `https` shows as plain text. An action that handed its work on (`outcome: started`, such as `job.run`) shows
"started", not "done", on its button and in the drawer. Every module is a title row, a body and a
footer saying how fresh its source is; every age is a live counter driven by one shared clock.

```bash
cd ui && npm install
npm run dev        # Vite on :5173, proxies /api and /healthz to 127.0.0.1:7474 (BRAIN_CONSOLE_DAEMON overrides)
npm run build      # writes ui/dist; the daemon serves it at / when it exists
```
The daemon prints `http://127.0.0.1:7474/?token=<t>` to the terminal it started in (and
`daemon:install` and `daemon:status` print it too): open that. The page takes the token
out of the address bar, keeps it in memory, sends it as a bearer header on fetches and as
`?token=` on the event stream. The built files themselves need no token: they are public code,
and every byte of state waits behind the API. One event stream per project carries snapshots
and action updates; when it drops the page reads `/snapshot` every 30 s and tries the stream
again. The action contract (`ActionKind`, `ActionRecord`) is the daemon's, in `snapshot.ts`.

## Develop
```bash
npm ci && npm --prefix ui ci
npm run check      # daemon tsc and node --test, then the UI's tsc, vitest and build
```
Tests use a fixture flow home under `daemon/test/fixtures` and a fake command runner, so no shell,
git or GitHub is touched. Test names are behavioural sentences and every assertion carries its
because-string, as the standards ask.
