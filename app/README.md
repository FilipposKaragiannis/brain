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
Projects also come from `BRAIN_CONSOLE_PROJECTS` (colon separated roots) or
`~/.config/brain-console/projects.json` (`{"projects":[{"root":"…"}]}`). Every root must hold a
`.flow/config.yaml`, or the daemon refuses to start. It binds `127.0.0.1` only and every route needs
the token, as `Authorization: Bearer <t>` or `?token=<t>`: `--token <t>` or `BRAIN_CONSOLE_TOKEN`,
else the one the daemon makes on first start and keeps in `~/.local/state/brain-console/token`.
The start log prints the URL with the token in it. A request whose `Host` is not a loopback
name, or whose `Origin` is not a local page, gets 403, so a page on another site cannot drive
the console even from the owner's own browser.

## Routes
| Route | What |
|---|---|
| `GET /healthz` | `{ok, projects}` |
| `GET /api/projects` | every project with its counts |
| `GET /api/projects/<id>/snapshot` | the current snapshot |
| `GET /api/projects/<id>/events` | SSE stream: `event: snapshot` on every change, a heartbeat every 15s |
| `POST /api/projects/<id>/refresh?source=<files\|git\|processes\|jobs\|board\|pulls>` | re-read one source now (all when omitted) |
| `POST /api/projects/<id>/actions` | run one action, body `{"kind","args"}`; 202 with the record, 400 on a bad request, 409 when its lock is held |
| `GET /api/projects/<id>/actions` | the recent 50 actions, newest first, with the output tail |
| `GET /api/projects/<id>/actions/<actionId>` | one action with its full output |

## The snapshot
`daemon/src/snapshot.ts` is the contract. One `Snapshot` per project: `project`, `sources`
(when each source was read and whether it worked), `counts`, `attention` (what needs a human,
oldest first), `worktrees`, `items`, `gates`, `runs`, `agents`, `jobs`, `pulls`, `events` and
`disagreements`. Timestamps are ISO UTC; every age is seconds at `takenAt`, so a reader keeps
counting on its own clock between snapshots.

One status language, used by worktrees and items alike:

| State | Meaning |
|---|---|
| `running` | an unattended agent process (`claude -p`, `codex exec`) has its cwd in the worktree, or a live run record |
| `needs-you` | its item has a gate record in `.flow/gates` |
| `stale` | the branch is ≥ 20 commits behind its base, or the claim is ≥ 72h old with no run, agent or gate |
| `claimed` | claimed, idle, nothing waits on you |
| `free` | no claim |
| `outside` | the main worktree or one not in the pool |

Flags add detail without changing the state: `dirty`, `behind`, `stale-branch`, `idle`,
`dead-run` (a run record with no process), `agent-without-claim`, `session` (someone's interactive
host is open in the folder).

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
| `files` | `.flow/config.yaml`, `gates/*.json`, `runs/*.json`, each pool worktree's `.flow/claim.json`, `events.log`, the plugin `.flow/plugin.sh` resolves, and when gates wait, `gate.sh list --json` for their questions (flow 1.18.0 and later; an older plugin, a failed list or a message with no numbered line falls back to the daemon's own parse) | 30s, and at once on any change under `.flow` |
| `git` | `git worktree list`, per worktree ahead/behind the base, dirty files, last commit | 30s, and after a file change |
| `processes` | `ps` + `lsof` for `claude`/`codex` processes and their cwd | 10s |
| `jobs` | `scripts/jobs.sh status --json` from the project's flow plugin | 60s |
| `board` | `scripts/board.sh --json` (asks the tracker; tens of seconds on GitHub) | 120s |
| `pulls` | `gh pr list` for the open PRs of `github.repo`, then one `gh api graphql` for their unresolved review threads (the first 100 per PR); a project not on the github adapter, or without `github.repo`, reports `ok` with `error: "not applicable: …"` and is never read | 60s |

The daemon itself never writes to a project. Every write goes through an action.

## Actions
An action is one flow script, run by path with argv and never through a shell, with every
argument checked against a shape first. The event stream carries `event: action` with the record
on every state change and at most twice a second while output arrives.

| Kind | Args | Runs | Lock |
|---|---|---|---|
| `gate.clear` | `item`, `message?` | `gate.sh clear <item> [<message>]` | the item |
| `run.start` | `item?`, `maxSteps?` | `jobs/next.sh <jobs.host> <item> --max-steps N`, detached; without an item `jobs.sh run next` | the item and the next job |
| `job.run` `job.stop` `job.pause` `job.resume` | `job` | `jobs.sh <verb> <job>` | the job |
| `worktree.claim` | `item` | `steward.sh claim <item>` | the pool and the item |
| `worktree.release` | `target`, `force?` | `steward.sh release <item or pool path> [--force]` | the pool and the item or worktree |
| `steward.health` | | `jobs.sh run health`, so the health job's own lock applies | the health job |
| `pr.merge` | `pr`, `method?` (squash) | `gh pr merge <pr> --repo <repo> --<method> --delete-branch` | the PR |
| `refresh` | `source?` | re-reads the sources in the daemon | none |

An item is `gh#12` or `local:task/7`; a release target is an item or the name of a pool worktree,
which the daemon turns into its path. An argument the kind does not take is refused, so a typo
never changes what runs. A second action on a held lock is refused with 409 and recorded as
`rejected`. At most four run at once. Scripts get two minutes, a merge three; a process that
ignores SIGTERM is killed with its group ten seconds later, and a timed-out action is `failed`
whatever its exit code. A run started with `run.start` is detached, writes its own output file,
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

## The UI
`ui/` is Vite + React 18 + TypeScript, plain CSS with custom properties (light and dark follow
the system). It reads the daemon's types straight from `daemon/src/snapshot.ts` (type-only
imports). Five screens, routed by hash (`#/<project>/<screen>/<detail>`): Overview (five tiles,
the needs-you table oldest first, the 3x3 pool map, the sources strip and the latest 30 events),
Gates (a decision card per gate, the questions and recommendations as the plugin parses them, so
the card matches the Slack message, Answer runs `gate.clear`), Worktrees
(Release, Health), Agents and jobs (Run, Stop, Pause, Resume) and Pull requests (from the `pulls`
source, with Merge on a PR in state `mergeable`). Every module is
a title row, a body and a footer saying how fresh its source is; every age is a live counter
driven by one shared clock.

```bash
cd ui && npm install
npm run dev        # Vite on :5173, proxies /api and /healthz to 127.0.0.1:7474 (BRAIN_CONSOLE_DAEMON overrides)
npm run build      # writes ui/dist; the daemon serves it at / when it exists
```
The start log prints `http://127.0.0.1:7474/?token=<t>`: open that. The page takes the token
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
