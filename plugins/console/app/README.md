# Brain Console

The control plane for the flow: one local daemon that watches every flow project on this
machine and serves a reconciled, live snapshot. The UI, a tray, a chat pane and an MCP server all
read that one shape. Node 24, TypeScript run as-is, no runtime dependencies.

## Run it
```bash
brain-console start --project /work/projects/foosbrawl   # one or more --project flags, else the settings file
brain-console open                                         # the page, token included
curl -s -H "Authorization: Bearer $(cat ~/.local/state/brain-console/token)" http://127.0.0.1:7474/api/projects/foosbrawl/snapshot | jq .counts
```
`brain-console` is the launcher `/console:install` writes (see the command, below). From a
checkout, the developer path is the same daemon through npm:
```bash
cd plugins/console/app && npm install
npm start -- --project /work/projects/foosbrawl            # node daemon/src/main.ts start …
curl -N "http://127.0.0.1:7474/api/projects/foosbrawl/events?token=$(cat ~/.local/state/brain-console/token)"  # server-sent events, one snapshot per change
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
brain-console install --project /work/projects/foosbrawl   # the same flags as start; none keeps the agent's
brain-console status                                       # loaded or not, the pid, the port and the URL
brain-console restart                                      # after an update, or a change of port
brain-console uninstall                                    # stop it and remove the agent
```
`install` checks the flags as a start would, then writes
`~/Library/LaunchAgents/com.brain.console.plist`: the absolute `node` and `daemon/src/main.ts`
(for an installed console the `~/.local/share/brain-console/current` link's path, never the
version's folder or the plugin cache, so an update needs only `brain-console restart`), `start`,
the flags with every path made absolute, `RunAtLoad` and `KeepAlive`, `PATH`, `HOME`,
`BRAIN_CONSOLE_LAUNCHD=1` (and `FLOW_PLUGIN`, `BRAIN_CONSOLE_PROJECTS`, `BRAIN_CONSOLE_STATE` and
`JIRA_API_TOKEN` when set) in `EnvironmentVariables`, the plist written `0600` since it may hold
that token, `Umask` 63 (077, so the log is the owner's alone), and stdout and
stderr to `<state dir>/daemon.log`; the state dir is closed to `0700`. It takes no `--token`: the
plist would keep the secret, so the daemon reads `<state dir>/token`. After booting a loaded job
out it refuses when something else holds the port and names it (`lsof`), such as an `npm start`
daemon; then it loads the plist with `launchctl bootstrap gui/$UID <plist>` (falling back to
`launchctl load -w` when bootstrap fails), waits up to 15 s for the port, asks
`launchctl print gui/$UID/com.brain.console` for the job's pid and reports it, and prints the URL
with the token to the terminal. `KeepAlive` starts a daemon that exits again about every ten
seconds, a bad config among the causes; such a daemon says in the log why it cannot start and that
launchd will keep trying until it is fixed or `brain-console uninstall` stops it. `uninstall` runs `launchctl bootout gui/$UID/com.brain.console` and removes the plist.
`status` says whether launchd has the job and reads the port and files from the plist's flags.
Settings says whether the daemon runs under launchd. In a checkout the same commands are the npm
scripts `daemon:install`, `daemon:status` and `daemon:uninstall`, not `install`: npm runs a
script named `install` on every `npm install`.

## The brain-console command
One command, `node daemon/src/main.ts <subcommand>` (the launcher `~/.local/bin/brain-console` once
`/console:install` has run). With no subcommand it prints this list.

| Subcommand | Does |
|---|---|
| `start [flags]` | runs the daemon here in the foreground, with the flags under Run it; writes `<state dir>/daemon.pid` (its pid, port, config and flags with every path absolute) while it runs, and refuses while that daemon still runs |
| `stop` | boots the launchd job out when it is loaded, else sends SIGTERM to the pid in `daemon.pid` |
| `restart` | `launchctl kickstart -k` for a loaded job, `bootstrap` for an agent on disk but not loaded, else stops the foreground daemon and starts it here with its flags |
| `status` | loaded or not, the pid, the port, the URL without the token, the config file, the state dir and the version; from a running daemon, the projects it watches, a change to the config file it refused (with the reason) and a newer console in the plugin cache than the one it runs (with `brain-console update`); exit 1 when nothing runs |
| `open` | opens the URL with the token in the default browser (`open`) |
| `url` | prints the URL with the token, for scripts; exit 1 when nothing runs |
| `add <path>` | adds a project (a folder inside a git checkout with `.flow/config.yaml`, relative to here or `~/`); through `PUT /api/settings` when the daemon runs, so it is watched at once, else into the config file with the same checks; refused when the launch agent names its projects with `--project` (`brain-console install --project …` changes those) |
| `remove <path>` | drops a project the same way; the last one stays |
| `logs [-f]` | the last 200 lines of `<state dir>/daemon.log` (the launchd daemon's), `-f` follows it |
| `install [flags]` | the launch agent, as under Run it on login; with no flags over an agent already written, its flags are kept |
| `uninstall` | boots the job out and removes the agent |
| `update` | when the newest `console` in `$CLAUDE_CONFIG_DIR` (else `~/.claude`)`/plugins/cache/*/console/*/`, then `~/.codex`, is newer than this one: runs its `scripts/install.sh --no-launchd --keep-old`, restarts a loaded job, removes the old versions once the new pid holds the port, and points `current` back and restarts the old version when it does not; else says it is up to date |
| `version` | the version |
| `help` | the list |

`/console:install` runs `../scripts/install.sh [--no-launchd] [--keep-old] [--project <root>]…`:
it copies this folder (without `node_modules` or `ui/dist`, through an archive so a failed read
fails) to `~/.local/share/brain-console/<version>/` (the version must be digits and dots), runs
`npm ci` and the UI build in a staging folder beside it, moves a same-version copy aside before
moving the new one in, points `current` at it, writes the launcher, adds each `--project`, runs
`brain-console install` unless `--no-launchd`, and removes the other versions unless `--keep-old`.
A step that fails after `current` moved points it back at the version before. Staging folders a
killed run left are removed on the next run. Under `BRAIN_CONSOLE_HOME` the launcher exports it,
so a later install or update from a plain shell stays in that home.

`stop`, `restart`, `status`, `open`, `url`, `add`, `remove` and `logs` find the daemon from the
launch agent's flags while launchd has it, else from `daemon.pid` in the state dir, which counts
only while its pid holds its port or runs `main.ts` (a pid reused after a crash is never signalled,
and the stale file is removed);
`--state-dir`, `--config` and `--port` point them at another one. The environment overrides what
a trial must not touch: `HOME` (the agent, the plugin cache, the default config and state),
`BRAIN_CONSOLE_HOME` (where the console is installed, default `HOME`), `BRAIN_CONSOLE_STATE`,
`BRAIN_CONSOLE_NODE` (the node the agent runs) and `BRAIN_CONSOLE_LAUNCHCTL` (the launchctl called).

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
While it runs, the daemon looks at the file's modification time once a minute and takes a hand edit
as a PUT (below) would, logging `config.reloaded`: new roots are watched, removed ones dropped
(projects set by a flag or the environment stay as they are), the terminal counts at once. A file
that does not parse or fails the PUT's checks is refused (`config.refused` in the log): the daemon
keeps what it runs, and `fileError` in the settings and `brain-console status` say why.

`PUT /api/settings` (the Settings screen) changes the settings its body names and keeps the rest:
the whole body is checked first (every root exists, is a folder inside a git checkout and holds
`.flow/config.yaml`, none is watched twice, no two share a folder name,
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
| `GET /api/settings` | the effective settings, each with `from` (`flag`, `environment`, `file`, `default`): the projects (and whether they can change here), the terminal and the installed ones, the port, the config file, the state folder and whether launchd runs the daemon, `fileError` (a change to the file the daemon refused, else null) and `newerConsole` |
| `PUT /api/settings` | change settings, body `{"projects"?, "terminal"?, "port"?}` as JSON; 200 with the new settings, 400 with the reason |
| `POST /api/settings/check-project` | body `{"root"}`: whether that folder can be added, with the same checks the PUT runs on the list plus it; 200 with `{root, id, ok, error, findings: [{check, ok, text}], initCommand}`, `check` one of `path`, `exists`, `flow`, `git`, `watched`, `name`, and `initCommand` (`cd '<root>' && claude /flow:init`) only while `.flow/config.yaml` is missing |
| `POST /api/open` | body `{"path", "with": "editor" \| "finder"}`: runs `open -t <path>` or `open -R <path>` (execFile, no shell) for the console settings file, the state folder (Finder only) or a watched project's `.flow/config.yaml`; 400 for any other path, 501 off macOS |
| `GET /api/projects/<id>/plugins/flow/config` | the project's `.flow/config.yaml` for the editor: `{path, text, hash, values, sections, warnings, hostDefaults}` (below) |
| `PUT /api/projects/<id>/plugins/flow/config` | change it, body `{"changes": [{"path", "value"}], "hash", "force"?}` or `{"text", "hash", "force"?}`; 200 with the new document plus `saved` and `followUps`, 400 with the reason, 409 with `reason: "stale"` or `"dirty"` |
| `GET /api/projects/<id>/snapshot` | the current snapshot |
| `GET /api/projects/<id>/agents/<pid>/transcript?lines=<n>` | `{session, turns, lines, bytes, turnCount}` of the claude transcript of an agent or session in `agents` or `ended`, oldest first: `turns` the last `n` turns with text (`[{at, role, text}]`, default 20, at most 200), user and assistant lines, their `message.content` text parts, without meta lines, side chains, tool calls or tool results, and without the host's wrapper turns (a user line that opens with a tag such as `<task-notification>`, `<local-command-stdout>` or `<command-name>`, and a compaction summary); `lines` the last `n` entries as one line each (`[{at, kind, text}]`, at most 2000; `kind` is `say`, `think`, `tool`, `result` or `user`, a result only when it failed, each text cut to 300 characters); `bytes` the file's size and `turnCount` its user and assistant entries. Read from the last 4 MB of the file, doubled up to 64 MB while it holds fewer lines than asked. 404 for a pid not listed or without a transcript, 400 for a codex session or a bad `lines` |
| `GET /api/projects/<id>/events` | SSE stream: `event: snapshot` on every change, `event: action` on every action update, `event: projects` (the project list) when Settings change it, a heartbeat every 15s; the stream of a removed project ends after that list |
| `GET /api/projects/<id>/events?item=<id>&limit=<n>` | the kept events as JSON instead, `{events, total, kept}`: newest first, only `item`'s when given, at most `limit` (default and cap 200); `total` is how many of the kept 200 matched before the limit, not every event the project ever logged. URL-encode the item (`item=gh%23213`: a bare `#` starts the fragment and never reaches the daemon). Any of `item`, `limit` or `Accept: application/json` asks for JSON; a bad limit is 400, any method but GET 405 |
| `POST /api/projects/<id>/refresh?source=<files\|git\|processes\|jobs\|board\|pulls>` | re-read one source now (all when omitted), then send the snapshot even when nothing changed, so the new read times show |
| `POST /api/projects/<id>/actions` | run one action, body `{"kind","args"}`; 202 with the record, 400 on a bad request, 409 when its lock is held |
| `GET /api/projects/<id>/actions` | the recent 50 actions, newest first, with the output tail |
| `GET /api/projects/<id>/actions/<actionId>` | one action with its full output |

## The snapshot
`daemon/src/snapshot.ts` is the contract; `schema` is its version, 10 since the snapshot took
`lessons`, `retros` and `counts.lessonsSinceRetro` (9 when an attention row took `gate`, 8 when
`project.trackers` took the place of `trackerUrl`, 7 when a gate and a pull took `quiz`, below).
One `Snapshot` per project: `project`, `sources`
(when each source was read and whether it worked), `counts`, `readiness`, `attention` (what needs
a human, oldest first), `worktrees`, `items`, `gates`, `runs`, `agents`, `ended`, `jobs`, `pulls`, `events`
(the latest 200, each with `at`, `item`, `kind` and `message`), `lessons`, `retros`, `disagreements` and `newerConsole`
(`{running, cached}` while the plugin cache holds a newer console with an install script than the
one the daemon runs, looked for at start and once a minute; null otherwise, and the page shows a
banner while it is set). Timestamps are
ISO UTC; every age is seconds at `takenAt`, so a reader keeps counting on its own clock between
snapshots.

- `project`: `id`, `name`, `root`, `flowHome`, `base` (the branch work merges into), `repo`
  (`github.repo`), `repoUrl` (`https://github.com/<repo>`, null without a repo), `adapter`
  (`adapters.default`, where new items go), `trackers` (each tracker the flow reads, in the order of
  `trackers`: `name`, `url`, the page of its items, GitHub's issues or
  `<jira.site>/browse/<jira.project>`, null for local, and `error`, why the last board read could
  not list it, from `board.sh --json`'s `tracker_errors`, or the console's own when jira is a
  tracker and its environment has no `JIRA_API_TOKEN`; null when it was read), `pluginVersion`, `pluginRoot`
  (the plugin's folder), `pluginSource` (`FLOW_PLUGIN` when the daemon was started with that
  variable, `installed` when `.flow/plugin.sh` found it in the plugin cache, null with no plugin),
  `jobsHost` (`jobs.host`, the CLI the jobs run), `jobHosts` (every host the jobs run on: the
  `host` of each schedule and of the next job's workers, sorted, once each; `[jobsHost]` when none
  says), `plugins`, `poolMax` and `reviewers` (`reviews.reviewers`
  without their `@`, every list of a per-host map once, codex and claude when unset: who the PR
  cards offer for a review ask).
- `plugins` is the plugins of flow's marketplace either host has for the project, by name, each
  `{name, marketplace, claude, codex}` with that host's version or null. The marketplace is that of
  the flow install Claude loads for the project (`flow@<marketplace>` in Claude's list: the
  project's own entry, else the user one; another project's entry never decides), else of the flow
  folder in the Codex cache, else of the cache folder the project's flow sits in, else
  `brain-plugins`. `claude` is from `~/.claude/plugins/installed_plugins.json`: the entry whose
  `projectPath` is the project root (project or local scope), else the user one. `codex` is the
  newest version folder (dotted numbers compared as numbers) under
  `~/.codex/plugins/cache/<marketplace>/<name>/` when `[plugins."<name>@<marketplace>"]` ends up
  with `enabled = true`: `<root>/.codex/config.toml` overrides `~/.codex/config.toml` per plugin
  (the last `enabled` in a table counts), so the project can turn one on or off. Read with
  the `files` source; a missing or broken file counts as none. The home is injected
  (`daemon/src/collectors/plugins.ts`).
- `jobs` has one entry per schedule `jobs.sh status --json` lists (flow 1.26.0): every job, then
  the named schedules (`next-codex`) in config order, then the installed ones the config no longer
  names. `name` is the schedule, `job` the script it runs (`next` for `next-codex`), `host` the
  host its args name or else `jobs.host` (null when the plugin does not say), and `configured`
  false only for a schedule installed here that the config dropped. On a plugin before 1.26.0 a
  row has no `name`: the console takes `job` as the name and the job as its part before the label.
- A worktree carries `agents` and `sessions`, each a list of `{pid, host, command, elapsedSeconds,
  session}` (the command cut to 200 characters), `item`, `itemUrl` and `itemTitle` (from the board, null
  without an item or before the board is read), and `staleReason`: "branch is 35 commits behind
  main (limit 20)", "claimed 6 days ago with no run, agent or gate", both joined with "; ", or null.
  `syncPending` is the refs the flow's sync note for the claimed item names, one per line in
  `<worktree>/.flow/reports/<item slug>/sync.md` (the flow's `reports_dir` for a work step, the
  slug being the id with `:`, `/` and `#` made `-`), read by the `files` source with the claim; null
  with no claim, no note or an empty one. The health job writes the note for a merge it cannot make
  cleanly and `sync.handoff` for a conflicted sync; the item's next run merges it first.
- `session` (on those and on every entry of `agents`) is the process's transcript,
  `{host, id, transcript, resume}`, or null when none was found. For claude it is first
  `~/.claude/sessions/<pid>.json`, which claude writes for every running process: its `sessionId`,
  taken when its `cwd` is the process's and its `procStart` is within ten seconds of the process's
  start (else it is a file an earlier process with that pid left); the transcript is
  `~/.claude/projects/<cwd with every character but letters and digits made "-">/<id>.jsonl`. Only
  without that file does it fall back to file times: the newest `*.jsonl` in that folder written
  at or after the process started (now minus its elapsed time, with two seconds for ps's
  rounding); the id is the file name. A transcript never goes to two pids: the sessions file
  wins, then the first process listed, and another claimant gets null, so an agent in the root
  never gets the owner's own session there. A scan's answer is kept per pid for the life of the
  process (a miss is scanned again a minute later), so a read costs one small file per claude
  process. For codex `~/.codex/session_index.jsonl` has ids and thread
  names but no folder, so the session files under `~/.codex/sessions/<yyyy>/<mm>/<dd>/` (the
  start's day back to fourteen days) are read instead: the newest written since the start whose
  first line, `session_meta`, names the same cwd; the id is its `payload.id`. Those first lines
  are kept in memory and forgotten fourteen days after the file was last written. `resume` is the argv
  that opens it again: `["claude", "--resume", id]` or `["codex", "resume", id]`. The home folder
  and the clock are injected (`daemon/src/collectors/sessions.ts`).
- `ended` lists the agents and sessions with a session that left the process list while the
  daemon watched, in the last 24 hours, at most 10, newest first: an `agents` entry plus `endedAt`
  (when the read that missed it ran). It lives in the daemon's memory, so a restart empties it.
- An item's `url` is its tracker page, from the board. Its `spend` is `{costUsd, sessions,
  tokens}`, summed over the step sessions `board.sh --json` counts from `log/runs.jsonl`, or null
  when it has none or the plugin prints no `spend`. Codex reports no cost, so a codex session adds
  sessions and tokens but no dollars.
- An item whose merge gate waits on review is `in-review`, not `blocked`: its PR has changes
  requested, a reviewer requested, or a reviewer the flow asked by a mention that has not
  answered. Its gate leaves `gates` and the attention list while that lasts.
- A gate carries `pull`: `{number, url, state, unresolvedThreads}` for its item's open PR (the one
  its `pr` field names, else the one on its claimed branch, whatever order GitHub lists them in),
  or null. A merge gate whose PR still
  has an unresolved thread shows it there.
- A gate and a pull carry `quiz`: the quiz the flow's explain step wrote for the item,
  `<reports>/quiz.md` (the claimed worktree's reports first, then each pool worktree's, then the
  main one's, as `steward.sh reports` looks), parsed as `{file, title, questions, result}`. Each
  question is `{number, text, choices: [{key, text}], answer, because}`: the right letter from the
  file's `<!-- answers: 1b 2a -->` key (null when the key leaves it out, so it is never right) and
  the `Because:` line that says why. `result` is the last try `quiz.sh answer` kept beside it,
  `<reports>/quiz.json`, as `{at, right, total, passed, given}` (the letter given per question
  number), or null before a try. A pull's quiz is its item's; null with no item or no quiz. The
  `files` source reads them with the gates.
- A gate carries `session`: the `{host, id, transcript, resume}` of the session that raised it, or
  null. Only for a claude or codex gate on a claimed worktree (a step run from the root shares its
  folder with the owner's own sessions): of the transcripts in that worktree (`<claude
  folder>/*.jsonl`, or for codex a session file whose first line names the worktree, as above)
  written at or after 30 minutes before `raisedAt`, the one that started latest no later than 5
  seconds after `raisedAt`. A transcript's start is the first `"timestamp"` in its head (both
  hosts write one on the first line), read once per file; one without it is skipped. A session the owner opened in the worktree after
  the raise is never chosen, however new, while a discussion resumed since still matches, since it
  appends to the raising session's own file. It
  comes from the files on disk, so it outlives a restart that empties `ended`. Looked up with the
  `files` source and kept per item and `raisedAt` while the gate waits (a miss is scanned again a
  minute later).
- `readiness` is `{ready, waitingOnField, blocked, gated, nextInLineMissingField}` over open
  items that are not epics. The first four are buckets, each item in one at most: the next job can
  take it, only an empty field stops it (the whole backlog of such items), an open item blocks it,
  it waits at a gate. Running, claimed and stale items count in none, so the Overview can say in
  one line why nothing runs. `nextInLineMissingField` is the part of `waitingOnField` that is the
  next step of work already under way, so the UI can say "164 backlog items lack a field; 4 of
  them are the next step of work in progress".
- A `needs-field` attention row (and `counts.needsField`, equal to `nextInLineMissingField`) is
  kept for those next-in-line items only: open, not an epic, no step, no open blocker, a `needs`
  that is not empty (a field `ready.needs` asks for, such as priority or size, is empty, so the
  next job refuses it), and either its parent has started (a step, a worktree, a PR or a gate), a
  sibling under the same parent has started or is done, or it blocks an item that has started.
  Every other item waiting on a field is backlog and gets no row. The row's `detail` names the
  fields: "needs priority", "needs priority and size".
- An attention row carries `gate`: the gate's kind on a `gate` row (`merge`, `escalation`,
  `plan-approval` …), which its chip shows, and null on every other row.
- `lessons` is every lesson in `<flow home>/lessons.jsonl` (one JSON object per line, written by
  the flow's `lesson.sh`), oldest first, each `{line, at, kind, item, step, rule, text, host}`:
  `at` the line's `time`, an empty field null, an empty kind `other`. `line` is the lesson's
  place among the file's non-empty lines, as `grep -c .` counts them, a malformed line included;
  a line that is not a JSON object is skipped, never a failed source.
- `retros` is every retro, newest first, each `{date, at, lessonsRead, lessonsReadSoFar, findings,
  applied, report}`. A line of `<flow home>/retros.log` (`<time>\t<lessons read so far>\t<findings>\t<applied>`,
  the meta retro skill's step 4) is one run: `date` the day of its time, `lessonsReadSoFar` its
  second column, `lessonsRead` that less the line before's (its whole count when it is smaller,
  the file having been reset, as the retro job counts), `findings` and `applied` the last two
  columns as written. A line without a time and a whole count is skipped. `report` is
  `<flow home>/reports/retro-<date>.md` as `{file, text}`, held by the last run of its day, else
  null; a report no line names is a run of its own with `at`, `lessonsRead` and
  `lessonsReadSoFar` null. `counts.lessonsSinceRetro` is how many lessons sit on a line past the
  last run's `lessonsReadSoFar`, every lesson with no run or with a count past the file's lines.
  Since flow 1.31.0 these files stay on the machine under `.flow/` and out of git; a missing one
  is no lesson and no retro.

One status language, used by worktrees and items alike:

| State | Meaning |
|---|---|
| `running` | an unattended agent process (`claude -p`, `codex exec`) has its cwd in the worktree, or a live run record |
| `needs-you` | its item has a gate record in `.flow/gates` |
| `stale` | the branch is ≥ 20 commits behind its base, or the claim is ≥ 72h old with no run, agent or gate; never a reservation |
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
| `in-review` | the health job's record says a reviewer it asked by a mention has not answered, and GitHub alone would say `review-pending`, `approved` or `mergeable` |
| `approved` | approval is satisfied (approved, or no review required) but a review thread is unresolved, or GitHub does not let it merge yet (merge state `BLOCKED`, `BEHIND`, `UNKNOWN`, or `mergeable` not `MERGEABLE`) |
| `mergeable` | checks green, approval satisfied, no unresolved thread, `MERGEABLE`, merge state `CLEAN`, `HAS_HOOKS` or `UNSTABLE`: ready to merge |

The PRs are those of `github.repo`, read whatever tracker holds the items (local, GitHub or Jira),
since the flow opens every item's PR there. A PR belongs to the item whose `pr` field names it (a
number such as `#20`, or its URL compared without case or scheme), whichever tracker holds it,
else to the item claimed on its head branch unless the PR comes from a fork, else to the open item
that records no PR whose task branch, `flow/<slug>` with the flow's `item_slug` (`gh#134` is
`flow/gh-134`, `local:task/3` is `flow/local-task-3`), is its head branch, so a PR whose `link-pr`
failed still finds its item; that gives its worktree. A PR's `mergeState` is GitHub's merge state
status as read (`CLEAN`, `BLOCKED`, `BEHIND`, `UNSTABLE`, …), null when GitHub gave none. `checks-failing`, `changes-requested` and `mergeable` each add an attention row
(`pr-failing`, `pr-changes-requested`, `pr-mergeable`), and `counts` carries `pullsFailing`,
`pullsChangesRequested` and `pullsMergeable`. A PR's `review` is the health job's record for it,
`.flow/reviews/<n>.review.json`: `{state, waiting, cannot, at}`, where `cannot` lists the
reviewers that replied they cannot review here, each `{reviewer, said}` with their own words.
Null without a record.

## Sources and cadence
| Source | How | Every |
|---|---|---|
| `files` | `.flow/config.yaml`, `gates/*.json`, `runs/*.json`, each pool worktree's `.flow/claim.json`, `events.log`, `lessons.jsonl`, `retros.log`, `reports/retro-*.md`, the plugin `.flow/plugin.sh` resolves, and `gate.sh list --json` for the questions of a gate whose message it has not parsed yet¹ | 30s, and at once on any change under `.flow` |
| `git` | `git worktree list`, per worktree ahead/behind the base, dirty files, last commit | 30s, and after a file change |
| `processes` | `ps` + `lsof` for `claude`/`codex` processes and their cwd. The program is the first word of the command, joined across a space only while the path runs on inside an `.app/` bundle or `Application Support/` (where the Claude desktop app keeps its CLI), so `sh /usr/local/bin/claude` or `node …/claude` is the wrapper, not the host. A host's own servers never count, named by the first two words after the program that are not options (`claude daemon run`, the Codex desktop app's `codex app-server --listen unix://…`, `codex app-server daemon pid-update-loop`, `codex -c … exec-server`), so a prompt that mentions a daemon is still an agent | 10s |
| `jobs` | `scripts/jobs.sh status --json` from the project's flow plugin | 60s |
| `board` | `scripts/board.sh --json` (asks the tracker; tens of seconds on GitHub) | 120s |
| `pulls` | `gh pr list` for the open PRs of `github.repo`, then one `gh api graphql` for their unresolved review threads (the first 100 per PR); a project without `github.repo` reports `ok` with `error: "not applicable: …"` and is never read; whatever tracker holds the items, the flow keeps their PRs on GitHub, so the tracker does not matter | 60s |

¹ Flow 1.18.0 and later. The parse is kept per gate until its message changes, so a waiting gate
costs no process after its first read. An older plugin is not asked. A list that fails, times out
(10s) or prints no JSON leaves the gate in place with the daemon's own parse, puts the reason on the
`files` source (`ok` stays true) and logs `gates.list.failed` once. A message with no numbered line
gets no questions from the plugin and shows as one question with no recommendation.

The daemon itself never writes to a project but in two places: the flow settings editor below,
which writes `.flow/config.yaml` when the owner saves, and `sync.handoff`, which writes the item's
sync note. Every other write goes through an action's script.

## Flow settings
`daemon/src/plugins/flow/` edits the project's `.flow/config.yaml`. `schema.ts` is a fixed schema
of every key the flow plugin reads (its scripts, `skills/init/SKILL.md` and the foosbrawl file):
the dotted path, a plain label the form shows in its place ("Base branch" for `base`), the type (`string`, `number` with a range where one is known, `boolean`, `enum`
with its values, `enumOrText` with its known values but any text allowed, `list` of text, `map` of name to text, `duration` like `1h`, `schedule` like
`every 30m --workers 2`, `daily 02:00` or `weekly sun 07:00` with the args `jobs.sh` takes), one
sentence on what changing it does, its group, which is its page in Settings (`GROUP_FAMILY` puts each under Plugins › Flow: Tracker,
Readiness, Worktree pool, Gates and verification, Reviews, Notifications; under Jobs: Schedules,
Next job, Health job, Comments job, Retro job, Intake job; or Agents), an optional `part` that
heads a few fields inside a page (Tracker: "Where items come from", "Where new items go", "GitHub" and "Jira"; Notifications:
"Channels" and "When to notify"; Agents: "Claude", "Codex" and "Deprecated"), a `placeholder`
with a concrete example for every free-text key, `adapter: 'github'` or `'jira'` on the keys only
that adapter reads (hidden, with a line saying why, while it is no tracker; `github.repo` has none,
since the PRs are on GitHub for any tracker), `keys` for a map with fixed names (`github.fields`: size, priority, area;
`github.status`: backlog, ready, gate, running, review; `jira.types`: epic, task, bug; `jira.fields`:
size, area), `values` for a list of fixed choices
(`ready.needs` and `trackers`), `deprecated` on `github.ready_needs` and `github.priority_order`
(the form starts `ready.needs` and `ready.priority_order` at them while the file leaves those out; an empty list saved there counts as set), `rows` for a map of free names (`gates`), and its follow-up: `jobs.schedule.*` and
`jobs.host` need `jobs.sh install` to reload the schedule launchd runs (the `jobs.install` action,
offered only while some job keeps a schedule, since install exits 2 when none has); a job whose
`jobs.schedule.<job>` is removed or emptied is never touched by install again, so it gets
`jobs.sh uninstall <job>` (the `job.uninstall` action, one per job) instead;
the pool keys (`pool`, `pool_max`, `worktree_copy`, `worktree_setup`) count at the next claim.

The Agents page holds, per host, the model and effort of every unattended session
on that host without an agent of its own: the steps with no agent (design, implement, review,
explain) and the comments, intake and retro jobs (flow 1.20.0): `jobs.claude.model` (opus, sonnet, haiku,
fable), `jobs.claude.effort` (low, medium, high, xhigh, max), `jobs.codex.model` (gpt-6-astra,
gpt-6-sol, gpt-6-luna) and `jobs.codex.effort` (low, medium, high, xhigh), where empty or unset
takes the host's own default; they need no follow-up, the next job run reads the file. The two
models are `enumOrText`, since the plugin passes any model name on and checks only the efforts
and the host. The old `jobs.model` and `jobs.effort` are deprecated: the plugin still reads them
for a host whose `jobs.<host>` map is absent (a codex model there is a roster name, mapped as
`host_codex_model` maps it; `legacyJobsSetting` in `schema.ts` mirrors that). The form shows them
only while the file sets them to something, read-only, with the note "Deprecated: flow 1.20.0
reads jobs.<host>.model and jobs.<host>.effort, and this key only while jobs.<host> is absent. Set
those and clear these." and a Clear that saves that one key as null (the group's other unsaved
edits stay).

`GET` reads the file. `values` is the file as the existing parser (`daemon/src/yaml.ts`) reads it,
but only after `configDocument.ts` has checked that every line is in the flat format the file's
header names (two-space indentation, `key: value`, nested maps, `- item` or `[a, b]`); a tab, an
anchor or alias, a tag, a multi-line string, a flow map, a list of maps or a key set twice makes
`values` null with the line in `warnings`, and only Raw YAML can change it. `sections` is the
schema's groups in order plus, when the file has keys the schema does not know, an `Other` group
of them as text (or a list of text). A known key whose value does not fit its type is a warning.
`hash` is the sha256 of `text`.
`hostDefaults` is `{codex: {model, effort, profile} | null}`: `model` and `model_reasoning_effort`
from `~/.codex/config.toml` on every GET and save, as codex picks them: from `[profiles.<profile>]`
when a top-level `profile` names one, else from the top level (only `key = "value"` and
`key = 'value'` lines are read; either is null when the file does not set it), and `codex: null`
when there is no such file. Claude has no file that reliably names its default, so it has no entry and its help
says "the Claude CLI's default". The home folder is injectable (`home` in the editor's
dependencies), so the tests read a fixture.

`PUT` checks first and writes last. Each change is checked against its key's type, enum and range
(an unknown key takes text, or a list of text; `null` takes a key out). The text is then rewritten
in place: a known key changes only the value on its line (its trailing comment kept), a list only
its item lines, a map only its children's lines. A list is always written as a block, `key:` with
`  - item` lines under it (an inline `[a, b]` becomes one), and an empty list as a bare `key:`, as
flow:init writes an empty pool: the steward's `pool_add_entry` appends `  - <path>` under the key
line, and `yaml_get` in `lib/flow.sh` stops at an inline value, so an inline list would hide every
worktree appended after it; a key not in the
file goes under its section's last line, or at the end of the file; every comment, blank line and
key order stays. Where the two parsers would read a value differently it is refused with the
rule: a value holding ` #` (`lib/flow.sh` reads a comment there even in quotes), a tab anywhere in
a value (it ends the value there), and a value of a key that is not a list starting with `[` or
`{` (`lib/flow.sh` strips the quotes and reads `"[wip]"` as the list `wip`). The result must parse again and read back to the values sent, or nothing is written. `{text}`
saves the whole file, held to the same format and types. It is refused (409) when the file's hash is
not the one sent (it changed on disk since the GET, force or not), and when
`git status --porcelain -- .flow/config.yaml` shows a tracked file with changes unless the body
says `"force": true`. An untracked file saves with the note "not tracked by git", and a folder git
cannot read (not a checkout) saves with a note saying so. Saves on one project run one at a time;
just before writing the file is read and hashed again (the git check can take seconds, and the
steward may append to the pool meanwhile), and a change since is refused as stale. The text goes
to a temp file beside it with the old file's mode, renamed over the file in one step. After a
write the `files` and `jobs` sources are read again before the reply, the daemon logs one
`flow.config.saved` line with the keys that changed, and the reply carries `saved` (the leaf keys
whose value changed), `followUps` (`{note, action: {kind, label, args}, paths}`) and `notes`.

The `files` source reads the base merge limit from `jobs.health.behind_base`, the key `steward.sh`
reads. Console 0.5 read `health.behind_base`, which the plugin never did; until 0.7.0 that key
still counts when the new one is absent, and the daemon logs `config.deprecated` once saying to
rename it.

## Actions
An action is one flow script, run by path with argv and never through a shell, with every
argument checked against a shape first. The event stream carries `event: action` with the record
on every state change and at most twice a second while output arrives.

| Kind | Args | Runs | Lock | Outcome when done |
|---|---|---|---|---|
| `gate.clear` | `item`, `message?` | `gate.sh clear <item> [<message>]` | the item | `finished` |
| `run.start` | `item?`, `maxSteps?` | `jobs/next.sh <jobs.host> <item> --max-steps N`, detached; without an item `jobs.sh run next` | the item and the next job | with an item `started` while the run goes, `finished` once it ends well; without one `started` |
| `job.run` | `job` | `jobs.sh run <job>` | the job | `started` |
| `job.pause` `job.resume` | `job` | `jobs.sh <verb> <job>` | the job | `finished` |
| `job.stop` | `job` | `jobs.sh stop <job>` | a stop lock of the job's own, so it reaches a run `job.start` holds | `finished` |
| `job.start` | `job?` (next), `host`, `model?`, `effort?`; for next and comments also `item?`; for comments with an item also `pr?`, then the target in place of the item; for next also `workers?`, `maxSteps?`, `pick?` (a filter's name, not with an item) | `.flow/jobs/<job>.sh <host> [item] [--workers N] [--max-steps M] [--model X] [--effort Y] [--pick NAME]`, detached: one run outside the schedules (below) | the job, and the item when given | `finished` once it ends; `started` for a next run that hands the queue to workers; a comments run re-reads `pulls` too |
| `job.schedule` | `job` (a schedule name), `schedule` | writes `jobs.schedule.<job>` through the flow config editor, then `jobs.sh install <job>` | the schedule | `finished`; `jobs` and `files` are re-read |
| `job.unschedule` | `job` (a schedule name) | `jobs.sh uninstall <job>`, then takes `jobs.schedule.<job>` out of the config | the schedule | `finished`; `jobs` and `files` are re-read |
| `run.stop` | `item` | `steward.sh stop <item>`: ends the run's processes and removes its record, keeping the claim and the worktree | a stop lock of the item's own, so it reaches a run `run.start` or `job.start` holds | `finished` |
| `run.resume` | `item` | `steward.sh resume <item>`: clears a dead run's record and starts its step again, as the health job does | the item | `started` |
| `worktree.claim` | `item` | `steward.sh claim <item>` | the pool and the item | `finished` |
| `worktree.release` | `target`, `force?` | `steward.sh release <item or pool path> [--force]` | the pool and the item or worktree | `finished` |
| `worktree.reserve` | `name?` | `steward.sh reserve [--name <name>]`: a free worktree with no item under the name, git `user.name` when none is given; claim, sweep, health and next pass over it until a release | the pool | `finished` |
| `worktree.sync` | `target` | `daemon/scripts/sync.sh <worktree> <base>` (below) | the item and the worktree | `finished`; on a conflict the record's `conflict` |
| `sync.handoff` | `target`, `refs?` | writes the item's sync note, then `jobs/next.sh` as `run.start` with the item (below) | the item and the next job | `started` while the run goes, `finished` once it ends well |
| `item.step-sync` | `item` | `adapters/<adapter>/write-state.sh <item> step=<claim's step> last_event=<when> step <old> -> <new>, set by the console from the claim in <worktree>` (below) | the item | `finished`; `board` and `files` are re-read |
| `steward.health` | | `jobs.sh run health`, so the health job's own lock applies | the health job | `started` |
| `steward.sweep` | | `steward.sh sweep --lock`: frees the worktrees whose PR merged or whose item closed and clears their merge gates; exit 75 when a sweep already runs | the pool and the health job | `finished`; the `note` names the worktrees freed and the gates cleared, or says nothing landed |
| `jobs.install` | | `jobs.sh install`: writes and loads the schedule of every job `jobs.schedule` names | every job (`job:next`, `job:comments`, `job:intake`, `job:retro`, `job:health`) | `finished`; `jobs` is re-read; a job install left as it was because it was running ("left as it is" in the output) is named in the record's `note` |
| `job.uninstall` | `job` (one of the five) | `jobs.sh uninstall <job>`: unloads its launchd agent and removes its schedule file | the job | `finished`; `jobs` is re-read |
| `host.clear` | `host` | `gate.sh clear <host>`: removes the host's stopped flag, so its sessions start again | the host | `finished` |
| `pr.merge` | `pr`, `method?` (squash), `force?` | `gh pr merge <pr> --repo <repo> --<method> --delete-branch`, then `--admin` when `force` is `true`: the owner's rights merge past what branch protection requires (failing or missing checks, a missing approval, a branch behind) | the PR | `finished` |
| `quiz.answer` | `item`, `answers` (`1b 2a 3c`: a letter per question number) | `quiz.sh answer <item> 1b 2a 3c` (flow 1.29.0): grades the try against the key in `<reports>/quiz.md`, writes `<reports>/quiz.json`, logs one `quiz` event, and on a pass marks the item's draft PR ready for review (`comments.sh ready`) when it has one on GitHub. Refused on an older flow, which has no quiz.sh | the item | `finished`; `files` and `pulls` are re-read |
| `pr.review` | `pr`, `reviewer` (a name or GitHub login, `@` optional) | `comments.sh request-review <pr> <ask> <reviewer>` (flow 1.27.0): one mention comment with the flow's request marker, Copilot through the reviewers API, so the health job tracks and chases it; the ask is the PR step's own. Refused on flow before 1.27.0, whose script would ask every reviewer | the PR | `finished` |
| `terminal.open` | `path`, `job?`, `session?`, `gate?` | a terminal window in `path` (below); with `session` (a pid) one with that process's resume command; with `gate` (an item, `path` optional) one with the resume command of the gate's located `session` | none | `finished` |
| `refresh` | `source?` | re-reads the sources in the daemon | none | `finished` |

`ActionRecord.note` is what a finished action wants said beside its state (null for most); the
button and the drawer show it. `ActionRecord.conflict` is `{refs, files}` when a `worktree.sync`
ended in a merge conflict, null otherwise: `refs` the refs still to merge, the conflicting one
first and then any the script did not reach, in the order sync.sh tries them; `files` the files git
reported. Its `outcome` stays null, as for any failed action. `ActionRecord.outcome` says what a successful action did: `started` means the work was handed on
and goes on after the record (`jobs.sh run <job>` gives the job to launchd and returns in a
second), `finished` means the work is over. It is null while an attached action runs and on a
failed or rejected one. Every `jobs.sh run <job>` (`job.run`, `steward.health`, `run.start` without
an item) also re-reads its sources a second time five seconds after it returns
(`ActionPlan.refreshAgainMs`), so the run it started shows; a daemon that stops drops the wait.

`job.start` runs any of the five jobs once with its own host, model and effort, which replace
`jobs.<host>.model` and `.effort` for that run (flow 1.26.0); `item` is next's and comments' (a
comments run with an item is that item's pass now, which merges the base in first when its PR
conflicts), `workers` and `maxSteps` are next's alone, and each is refused for the others. It is refused while next is paused, since next.sh would
exit at once, and for an item with more than one worker. `job.schedule` takes a schedule name, a job
or `<job>-<label>` with a label of a lowercase letter then letters and digits, and a schedule line
as `_jobs.py` reads it: `every <n>m|h`, `daily HH:MM` or `weekly <day> HH:MM`, then an optional
host word and the job's args (letters, digits and `_./:=@%+,#-`, none opening with `#`). It is
refused while that schedule runs, and for the plain next schedule with `--workers` while
`jobs.workers` is set; a named next schedule runs its own `--workers`. `job.unschedule` unloads first, so an installed schedule the config already dropped is only
unloaded. `run.stop` and `run.resume` need a run record for the item; a resumed step shows in the
process list a few seconds later, so its sources are read again then.

`worktree.sync` brings a claimed pool worktree up to date. The target is an item or a pool
worktree's name, as for a release; the base is the claim's, else the project's. It is refused, each
with its own reason, while the worktree has uncommitted files, a run record in `.flow/runs` names
its item, or an unattended agent works in it. The script runs `git -C <worktree> fetch origin`,
merges the branch's own upstream when that is ahead, then `origin/<base>` when it exists (else the
local base), each with `merge --no-edit`; the output names every merge. A merge that conflicts is
undone with `git merge --abort` and the action fails with the conflicting files in its output,
then `console: still to merge: <ref> …`, which the record's `conflict` is read from.
A TERM or INT (a timeout, a removed project, the daemon stopping) mid-merge aborts the merge too,
so no `MERGE_HEAD` is left behind, and the script exits 143. When it ends `git` is read again.
`sync.sh --refs <worktree> <base>` prints the refs a sync would merge, one per line, without
fetching or merging.

`sync.handoff` gives the merge to the flow's sync step. The target resolves as for
`worktree.sync`. `refs` is newline separated (the UI passes the conflict record's); without it
the refs are `sync.sh --refs`'s, which come from what the last fetch of origin left (the output
says so; the sync step fetches before it merges). It is refused, each with its own reason, while
git has not read the worktree; while it has uncommitted files (as `worktree.sync` is); without
`refs` when the branch has every commit of its base (nothing to hand off; with `refs` a conflict
with the branch's own upstream is owed even then); while a run record names the item or an agent
works in the worktree; and wherever `next.sh` would pass the note over, since the health job
then drops it: while the item waits at a gate (a record in `.flow/gates` or the tracker's gate
field), while the item's step (the tracker's, else the claim's) is not a worktree step in the
plugin's step table (`steps.<step>.worktree` in its `profiles.json`, which `step_field` reads;
the `files` source reads it with the plugin, and an unreadable table refuses), and while the next
job is paused or a run of it goes (`jobs.sh status`). Once its locks are held the daemon, off its
event loop, writes the refs to `<claim's worktree>/.flow/reports/<item slug>/sync.md`, one per line
with a newline after each, the bytes `steward.sh`'s `health_branch_notes` writes, through a temp
file beside it renamed over it, so `next.sh`'s `-s` test never sees a half-written note; a note
already there with the same refs is left alone, and one with other refs is replaced with the old
refs named in the output. A note it cannot write fails the action before anything runs, and so
does a daemon that began stopping meanwhile. Until flow 1.20.4 the health job removes `sync.md`
whenever its own check finds nothing to merge (the branch has a PR, is at most `behind_base`
commits behind, or waits at a gate), so a note it did not write may be gone within one health
cycle if the run has not taken it by then. Then the
item's run starts exactly as `run.start` with that item starts it (detached, the same locks and
re-reads), and `next.sh` finds the note (`[ -s … ]`) and runs the sync step first, keeping the
item's own step for afterwards. The output opens with what was written and that the run's first
step is sync, and the daemon logs one `sync.handoff` line with the item, worktree, refs and the
refs it replaced.

`item.step-sync` settles a claim whose step differs from the tracker's by writing the claim's step
to the tracker, the claim being the agent's own record. It runs what `adapter write-state` in
`lib/flow.sh` runs, `<plugin>/adapters/<adapter>/write-state.sh` (the adapter from the id's
prefix, as the plugin's `adapters/<name>/prefix` files say: `gh#` github, `jira:` jira, `local:` local) with the item first, and writes the fields advance.sh writes
at every step change: `step`, and `last_event` saying the console set it. It is refused, each with
its own reason, when no pool worktree claims the item; while a run record names the item or an
agent works in its worktree, since the run moves the step itself; when the claim records no step,
or one that is not a step name; when it records the sync step, which runs ahead of the item's own
step and never moves it; and when the tracker already says the claim's step. The output opens
with the old and the new step, and the daemon logs one `item.step-sync` line.

### Sync
"Merge <base> in" ends one of three ways. Merged: every ref went in cleanly, the action is `done`
and the stale reason goes with the next git read. Conflict: the merge is aborted, the action is
`failed` with `conflict`, and the card lists the files with "Hand to the flow". Handed to the flow:
that button runs `sync.handoff`; the card says it is handing off until the files source reads
the note, then shows "sync pending: <refs>" until the sync step merges them (and drops the note), and a choice only the owner can make comes back as an escalation gate.

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

With `gate` (an item id; `job` or `session` with it is refused) the window opens in the worktree
the gate was raised in (a `path`, when given, must be it) with the resume command of the gate's
`session`, run at once, unless a listed live process writes that transcript. Only a gate in
`gates` with a located session; any other item is refused with the reason.

An item is an id that starts with the prefix of one of the plugin's adapters (the first line of
`adapters/<name>/prefix`, read with the flow files; `gh#` and `local:` for a plugin before flow
1.28.0, which has none), followed by a letter or digit and at most 127 of letters, digits and
`:#/_.-`, with no empty, `.` or `..` part between slashes (an adapter may join the id onto a
folder): `gh#12`, `local:task/7`, `jira:WID-7`. A release target is an item or the name of a pool worktree,
which the daemon turns into its path. An argument the kind does not take is refused, so a typo
never changes what runs. A second action on a held lock is refused with 409 and recorded as
`rejected`. At most four run at once, stops aside: `run.stop` and `job.stop` start on a full
runner too. Scripts get two minutes, a merge three; a process that
ignores SIGTERM is killed with its group ten seconds later, and a timed-out action is `failed`
whatever its exit code. A run started with `run.start` and an item is detached, writes its own output file,
holds its item for as long as it runs and is never killed by the console. `jobs/next.sh` takes
the next job's lock, so a console run while the scheduled job is busy prints "skipped" and ends
at once. When an action ends the sources it changed are re-read.

Every action is two lines in `~/.local/state/brain-console/<project>/actions.jsonl`, one at
start and one at the end, with its full output in `actions/<id>.log` beside it (`--state-dir`
or `BRAIN_CONSOLE_STATE` moves it). Inside the project the console writes only what the scripts
themselves write (`item.step-sync` through the flow's own adapter), the sync note `sync.handoff` writes and, from the flow settings editor,
`.flow/config.yaml`.

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
A claim whose step differs from the issue's is not shown at all while a run of the item goes (a
run record names it or an agent works in its worktree), since the run moves the step itself, and
once the run has ended it shows only after a board read that started after the end, on top of
that rule.

Every disagreement carries `explain`, one plain sentence saying what each store says and which is
usually right, and `action`, the button that settles it (`{kind, args, label}`) or null when a
person has to look:

| Stores | Usually right | Action |
|---|---|---|
| run record vs process list | the process list: the run ended or crashed | `steward.health`, "Run the health check" |
| process list vs claim | the process list: something runs there unclaimed | none |
| claim vs issue state (step) | the claim: it is the agent's own record, written first | `item.step-sync` with the item, "Set the issue's step to the claim's"; none when the claim names the sync step, which leaves the issue at the item's own step |
| claim vs issue state (worktree) | the claim: it lives in the worktree itself | none |
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
| needs-field | an item that is the next step of work already under way (its parent or a sibling has started, or it blocks started work) but lacks a field the tracker asks for (`ready.needs`, such as priority), so the next job passes it over |

## The UI
`ui/` is Vite + React 18 + TypeScript, plain CSS with custom properties (light and dark follow
the system). It reads the daemon's types straight from `daemon/src/snapshot.ts` (type-only
imports). Nine project screens, routed by hash (`#/<project>/<screen>/<detail>`), and Settings: Overview (five tiles,
Needs you, Running, Stale, Checks red and Free, each with a line under its count: the oldest wait
and its item, the steps running on which items, the stale worktrees, the red PRs and the free
worktrees; a
readiness line from `readiness` that says what runs, or why nothing does: how many items the next
job could take, how many next-in-line items lack a field and how many more in the backlog do, how
many wait at gates and how many are blocked; under it a line with the lessons since the last
retro (`counts.lessonsSinceRetro`, "No lesson since the last retro." at none) and a Retro link to
that page; Needs you, a list oldest first where each row has
its kind on a chip (a gate row names its gate there, `merge`, `escalation`, `plan-approval` …, so
a clipped title loses nothing; the PR rows come from the `pulls` source, so they show wherever
`github.repo` is set, whatever the trackers), its item and title over what it waits on, how long
it has waited with a bar that turns late at a day and old at two, and one button that settles it (the row's own action, else Decide,
Open PR, Fix, Fill in or Open), with the next-in-line items that lack a field folded after five;
beside it Running now, each agent's step, item, worktree, host and PR with its age, the last line
of the first claude transcript, and the scheduled jobs in the order they run next; then the latest
12 events with Show all; the disagreements, only when there are some, with what each store says
and the button that settles it; the pool map, a cell per worktree with its item, title and what it
waits on, striped while it runs; and the sources strip, with a small refresh button at the right of its
title that posts `/refresh` for every source, turns while the request is out and a moment after, and
shows a refusal beside it; and at the bottom a footer in small muted type, "Plugins from
<marketplace>", a row per plugin of `plugins` (flow first, then by name) with a Claude Code and a
Codex column, each the version or "—" where that provider lacks it, both cells in the needs-you
colour with the title "Claude Code and Codex differ" when the versions differ, the table scrolling
inside itself at phone width; under it the flow the scripts use, `pluginVersion` and where it came
from (`FLOW_PLUGIN` or the installed plugin, with its folder), or "No plugins found in ~/.claude
or ~/.codex." with none), Gates (a decision card per gate, one line on what
its kind asks, the PR with its state and unresolved review threads when the item has one, the
questions and recommendations as the plugin parses them on flow 1.18.0 and later, so the card
matches the Slack message, else the daemon's own parse, Answer runs `gate.clear`; Discuss with the
agent resumes the newest agent on the item in `agents` or `ended` by its pid, else the gate's
`session` with `gate`, and is left out with neither; a gate whose item
has a quiz shows it as a panel: a line with how many questions or the last try's score, Take the
quiz, which opens one radio group per question and a Check my answers button that grades the
letters on the page and runs `quiz.answer`; the results mark each question right or wrong, show
the right choice for a wrong one and each question's Because line, and say that a pass sends the
draft PR ready; a failed try has Take it again, a kept result has See results; a merge gate on a
draft with a quiz still to pass says so in place of the merge button), Worktrees (filter
chips with counts for all, running, needs you, stale, claimed and free, the pool size and base,
and Reserve, Run health and Sweep; a card per pool worktree with its name, state and flags, its item and title, its
branch, head and PR, its step, how many files are dirty and a bar of how far it is behind base,
its agents and sessions with pid, host and age and the command on hover, a Watch button to the
run or a Decide button to the gate, why it is stale and the way
out (for a branch far behind, a "Merge <base> in" button that runs `worktree.sync` when the
worktree is clean, has no run record and no agent, else the same words without the button;
after a sync that conflicted, the conflicting files folded after five and "Hand to the flow",
which runs `sync.handoff` with the conflict's refs, or while a run record names the item and its
note is there "A run is going; the sync step runs first when it starts", and between an accepted
hand-off and the first read of its note "Handing off to the flow"; and "sync pending:
<refs>" whenever `syncPending` is set, so a note the health job wrote shows too), Open in
Terminal on every card and Release on a claimed one, a reserved one saying who reserved it; then the worktrees outside the pool, the
project root included, in a table with their branch and Open in Terminal), Board (`#/<project>/board/<item>`: the open items with filters for
under way, in review, ready, blocked and backlog, each row with its state, step, worktree, PR and
spend, a head line summing the spend of the rows shown, a banner (`role="alert"`) for each
tracker the board could not read saying why its items are missing, and an item's detail beside the list:
its fields, its PR and who that waits on, and its cost, sessions and tokens), Agents (Runs across
the page: a card per live run, the first open and the
others folded to their header, each with its step, item, worktree, host and PR, its stats
(started, last commit, transcript size and turns, pid) and its transcript as a terminal of the
last 12 lines, with Full log (the last 2000 lines in a box that scrolls), Open session, Open in
Terminal and Stop this run (`run.stop`); a run record with no process is a dashed card with
Resume (`run.resume`); with no run, a link to Jobs. Then your own sessions, folded, and the runs
ended in the last day), Jobs (`#/<project>/jobs`, a main column and a side column. Schedules: a
card per schedule with its state, timing, host and args, the last
run, and Run now or Stop, Edit…, Pause or Resume, Unschedule and Open in Terminal in the row; its
history and workers open in a box of fixed height that scrolls; the jobs with no schedule fold
into one line. Edit… opens a dialog over the page with the schedule's timing, host, model and
effort, and for next its item, workers and max steps; saving runs `job.schedule` under the same
name. The side column holds a
card per stopped host with Clear (`host.clear`), the panel that adds a schedule of any job or runs
it once (`job.schedule`, `job.start`): a Job picker, then the name, the timing and the job's
settings, where only next takes an item and limits, an empty name making the job's own schedule
only while it has none; and the latest events), Pull requests (a head line of how many are open, in review and ready to merge, then a card per PR
from the `pulls` source: its state, item, agent or worktree and ages; four cells for checks,
conflicts, review and threads; the reviewers asked by a mention, each silent one "has not answered
yet" and each that cannot review with its own reply and the way out; Merge on a PR in state
`mergeable`, else why not (a draft whose item has a quiz still to pass says it goes ready when the
quiz is passed); Force merge, a red outlined button that is never the primary one, on a PR in
state `checks-failing` or `approved` with GitHub's merge state `BLOCKED` or `BEHIND`, which runs
`pr.merge` with `force=true` (never on `conflicts`, `draft`, `checks-pending` or
`changes-requested`); Resolve conflicts on a PR in state `conflicts` with an item, which runs
`job.start` for the comments job on `jobsHost` with that item and the PR's number (the item may have
no PR recorded when the card found it by its task branch), and while it runs the card says a
comments pass is running and merges the base in first; the same quiz panel as the Gates card when
the PR's item has one; and, on a PR that is not a draft, "Ask for review from" with the project's
reviewers, then each of codex, claude and copilot not among them, then "other…" for a GitHub
login, whose Ask runs `pr.review`; a merge gate's
card has the same ask. Before that source is read, or off GitHub, a table of the items with a
PR) and
Activity (`#/<project>/activity/<item>`: every kept event from `/events?limit=200`, narrowed to one
item with the filter box; a failed read shows a banner over the last events and is tried again every
10 s), and Retro (`#/<project>/retro`, its nav entry saying "<n> new" while lessons wait for a
retro: a head line with the lessons in all, those since the last retro and when the last retro
ran, and "Run retro now" with a host picker (the retro schedule's host, else `jobsHost`), which
runs `job.start` with `job: retro` and the config's model and effort; Lessons, by kind then by
rule, the kinds and rules with the most lessons first and the lessons naming no rule last, each
with its text, item, step, host and day, the lessons since the last retro first and All a tab
away; Retros, newest first, each with its day and time, the lessons it read and the log's findings
and applied columns, its report rendered as markdown, the newest open and the others folded). A
row above every screen holds the project's fields, each a small uppercase label over its
value: Project (the name; its title is the root), Repository (`owner/name`, linked), Tracker, or
Trackers for several (each tracker the flow reads: "GitHub issues" and "Jira" linked to their
items, "local" plain; one the board could not read followed by "(not read)", its title the reason), Base branch
and Jobs run on (`jobHosts`, every host the schedules and their workers run on, e.g.
`claude, codex`); the plugins and their versions are in the Overview's footer. The top bar holds the Settings button, and
the theme switch is a small square icon (a moon on light, a sun on dark) kept per browser. At phone
width the fields wrap. Settings (`#/settings`, linked from the top bar of every screen) shows one page at a time
beside a menu: General; Projects; Plugins › Flow with the Flow pages; Jobs with Schedules and
Configuration; and Agents. Plugins, Flow and Jobs expand and collapse with a chevron, open at
first; the browser keeps which are closed, and the group holding the page on screen stays open.
Configuration shows a trail, Configuration › Next, Health, Comments, Retro, Intake, one button per
job: only the chosen job's settings show, the choice holds while you move between pages, and a
draft on one job waits while another shows. With two projects or more, a picker at the top of the menu chooses the project the
Plugins, Jobs and Agents pages edit. General (where the page opens) has Terminal, radio buttons for
the first installed, iTerm, Terminal, Ghostty or a custom command as a JSON array, checked as you
type; Daemon, the port it listens on now with a box to save another for the next start, the
restart note, and whether it runs under launchd or a terminal; and Files, the config file, the
state folder and each project's `.flow/config.yaml` with Show in Finder, over each project's Raw
YAML. Projects lists the watched projects with Remove, or the note why they cannot change, and
Add a project, a wizard in four steps: the folder; the daemon's check of it, a mark per finding
and, when `.flow/config.yaml` is missing, the flow:init command to run there and Check again; the
name and root to confirm; and a link to the new project's overview. A refused save shows the
daemon's reason. A flow page
edits the project's `.flow/config.yaml`: the note "This edits
.flow/config.yaml in the project. It is a tracked file: commit it there.", the file's warnings,
then the page's fields under their part headings (each labelled in words with its key under the
label and the help under the control, with a concrete example in an empty box). The control
follows the field: a select for an enum or a boolean with "(not set)" to take the key out, a number
or text box, a text area of one item per line for a list, checkboxes for a list of fixed choices, a
labelled box per name for a map with fixed names (empty leaves the name out), rows of name and
command with Add a check for `gates`, a switch and a count per host for `jobs.workers` (a host
switched off is left out, and the last one cannot be), and for a schedule the timing as dropdowns
and fields, then the host ("jobs.host" keeps following it), the model and effort, for next the
item, workers and max steps, and the job's other options, with Edit as text, Unschedule and, for an
empty key, Schedule it; a line the builder cannot hold whole stays a text box with a note. The
GitHub issue keys show only while the flow reads github (`trackers`, else some `adapters` key
names it), and the Jira part only while it reads jira, else one line saying so; the GitHub
repository shows always, since the PRs are on GitHub whatever the tracker. The keys the file sets come first and the rest fold under "N more settings the
file leaves at the default". Every page of a project is one form: an edit waits while you move to
another page, and one save bar at the bottom counts the unsaved changes and which pages hold them,
with Discard and Save changes, which sends them all in one write. On Agents, both hosts' model and effort dropdowns show, each listing its values and "host default"
for empty and, for a model, "other…" that opens a text field (a name off the list starts there),
the help under it naming the default (for codex the one `hostDefaults` read, "On this machine
that is gpt-6-sol"). While a host has no map and a
deprecated key is set, its dropdown starts at what the jobs really run with, under it "now opus,
from the deprecated jobs.model". A save of either of a host's pair writes both, "host default" as an
empty line, so the `jobs.<host>` map is there and the fallback ends. A deprecated `jobs.model` or
`jobs.effort` the file sets shows read-only with its note and a Clear button. A save shows the fields written and each follow-up,
with a "Reload the schedule" button (`jobs.install`) when a schedule or `jobs.host` changed and an
"Unload <job>" button (`job.uninstall`) for each job whose schedule was removed, and any note (a
file git does not track); a
refusal shows the reason, with Save anyway for a file with uncommitted changes and Reload for one
that changed on disk. Raw YAML, under General, holds the whole file in a text area with Save YAML and Open, which
opens it in the default text editor (it opens on the flow pages too when the file is not in the
flat format). Every item id opens its tracker
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
../tests/run.sh    # the plugin's installer and brain-console update, under a fake home with a fake npm
```
Tests use a fixture flow home under `daemon/test/fixtures` and a fake command runner, so no shell,
git or GitHub is touched, with one exception: the flow settings tests cut `yaml_get` out of
`plugins/flow/lib/flow.sh` and `pool_add_entry` out of `steward.sh` and run them with `sh` on a
temp file, so a list the console writes is checked against the reader the flow scripts use; the
sync note tests do the same with `health_branch_notes`, `reports_dir` and `item_slug`, and the
`-s` test and brief line of `next.sh`. The sync tests run `sync.sh` and the actions over it
against real git in a temp folder. Test names are behavioural sentences and every assertion carries its
because-string, as the standards ask.
