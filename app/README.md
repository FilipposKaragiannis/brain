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
`.flow/config.yaml`, or the daemon refuses to start. It binds `127.0.0.1` only; `--token <t>` (or
`BRAIN_CONSOLE_TOKEN`) guards every route with `Authorization: Bearer <t>` or `?token=<t>`.

## Routes
| Route | What |
|---|---|
| `GET /healthz` | `{ok, projects}` |
| `GET /api/projects` | every project with its counts |
| `GET /api/projects/<id>/snapshot` | the current snapshot |
| `GET /api/projects/<id>/events` | SSE stream: `event: snapshot` on every change, a heartbeat every 15s |
| `POST /api/projects/<id>/refresh?source=<files\|git\|processes\|jobs\|board>` | re-read one source now (all when omitted) |
| `POST /api/projects/<id>/actions` | run one action, body `{"kind","args"}`; 202 with the record, 400 on a bad request, 409 when its lock is held |
| `GET /api/projects/<id>/actions` | the recent 50 actions, newest first, with the output tail |
| `GET /api/projects/<id>/actions/<actionId>` | one action with its full output |

## The snapshot
`daemon/src/snapshot.ts` is the contract. One `Snapshot` per project: `project`, `sources`
(when each source was read and whether it worked), `counts`, `attention` (what needs a human,
oldest first), `worktrees`, `items`, `gates`, `runs`, `agents`, `jobs`, `events` and
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

## Sources and cadence
| Source | How | Every |
|---|---|---|
| `files` | `.flow/config.yaml`, `gates/*.json`, `runs/*.json`, each pool worktree's `.flow/claim.json`, `events.log`, the plugin `.flow/plugin.sh` resolves | 30s, and at once on any change under `.flow` |
| `git` | `git worktree list`, per worktree ahead/behind the base, dirty files, last commit | 30s, and after a file change |
| `processes` | `ps` + `lsof` for `claude`/`codex` processes and their cwd | 10s |
| `jobs` | `scripts/jobs.sh status --json` from the project's flow plugin | 60s |
| `board` | `scripts/board.sh --json` (asks the tracker; tens of seconds on GitHub) | 120s |

The daemon itself never writes to a project. Every write goes through an action.

## Actions
An action is one flow script, run by path with argv and never through a shell, with every
argument checked against a shape first. The event stream carries `event: action` with the record
on every state change and at most twice a second while output arrives.

| Kind | Args | Runs | Lock |
|---|---|---|---|
| `gate.clear` | `item`, `message?` | `gate.sh clear <item> [<message>]` | the item |
| `run.start` | `item?`, `maxSteps?` | `jobs/next.sh <jobs.host> <item> --max-steps N`, detached; without an item `jobs.sh run next` | the item, or the next job |
| `job.run` `job.stop` `job.pause` `job.resume` | `job` | `jobs.sh <verb> <job>` | the job |
| `worktree.claim` | `item` | `steward.sh claim <item>` | the pool |
| `worktree.release` | `target`, `force?` | `steward.sh release <target> [--force]` | the pool |
| `steward.sweep` `steward.health` | | `steward.sh sweep` / `health` | the pool |
| `pr.merge` | `pr`, `method?` (squash) | `gh pr merge <pr> --repo <repo> --<method> --delete-branch` | the PR |
| `refresh` | `source?` | re-reads the sources in the daemon | none |

A second action on a held lock is refused with 409 and recorded as `rejected`. At most four run
at once. Scripts get two minutes, the steward ten, a merge three; a run started with `run.start`
is detached and never killed. When an action ends the sources it changed are re-read.

Every finished action is one line in `~/.local/state/brain-console/<project>/actions.jsonl`,
with its full output in `actions/<id>.log` beside it (`--state-dir` or `BRAIN_CONSOLE_STATE`
moves it). Nothing is written inside the project except what the scripts themselves write.

## Reconciliation
`daemon/src/reconcile.ts` is a pure function from the collected facts to the snapshot, with the
clock injected. It derives states, ages, the attention list and the disagreements between the six
places flow state lives (claims, gate records, run records, the process list, issue labels and
state, the project card): a run record with no process, an agent in a worktree without a claim,
a claim whose step differs from the issue, a gate record the labels do not show, an item at step
done with an open PR and no merge gate.

## Develop
```bash
npm run check      # tsc, then node --test
```
Tests use a fixture flow home under `daemon/test/fixtures` and a fake command runner, so no shell,
git or GitHub is touched. Test names are behavioural sentences and every assertion carries its
because-string, as the standards ask.
