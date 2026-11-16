# Design: the flow owns its state (gh#171)

The architecture for every slice of gh#171; the last section, "Slice 1a build", is the build contract of the first one (gh#180). Commit this file whole as `docs/design/flow-owns-its-state.md`.

Citations are under `plugins/flow` unless they name the console: a bare script is `scripts/`, `_gh.sh`, `_query.py` and `_mutate.py` are `adapters/github/`, `_jira.py` is `adapters/jira/`. Section 1 and the 1a build cite `main` at flow 1.38.2, after gh#167 (the `base` key) and gh#170 (the gate record, ADR 0003). Sections 2 to 6 were written at 1.36.0: their flow and adapter lines are refreshed here, their console and test lines are not, and the slice that builds a section refreshes them.

## Goal
- One flow-owned record per item holds every workflow fact; adapters read and write only what the tracker models.
- Readiness reads the tracker's own signals (category, assignees); health repairs drift by a fixed table.
- Non-goals: `state.branch` (slice 7); the other per-item files (`kept-whole/`, `health/*.seen`, `reviews/`); a retro reader of the archive; new adapters.

## Decision
The record is one JSON file per item behind one module (`scripts/_state.py` and its pure half `scripts/_state_schema.py`, faced by `lib/state.sh`). Readers keep today's shape: the flow joins the record onto each adapter item as `state`, so `state_get` (`lib/flow.sh:385`), the Python readers and the console's `BoardItem.state` keep working while the source moves. Writers keep today's grammar: `record_set <item> key=value...` takes the twenty keys (`adapters/README.md:101-111`). The gate record of ADR 0003 becomes the record's `gate`. Until slice 4a every write goes to the tracker first, through `write-state`, and must land there (the mirror), so each slice lands green and a tracker failure fails a write exactly as it does today. The tracker gains three native ops (`set-status`, `assign`, `me`) and loses `write-state` and `sync`.

## Modules
| Module | Job |
|---|---|
| `scripts/_state_schema.py` (new) | the record as data, pure: schema, key map, pair grammar, merge, seed, the twenty keys read back, view shapes |
| `scripts/_state.py` (new) | the record on disk: arguments, lock, atomic write, views, archive; later join, status derivation, import |
| `scripts/_state_arguments.py` (new) | the command line of `_state.py`, pure and hand-written: argparse and dataclasses were most of each write's Python start |
| `lib/state.sh` (new, sourced by `lib/flow.sh`) | the shell face below, and the one place a record write meets the tracker; no script opens a record file |
| `scripts/state.sh` (new) | CLI for tests, skills and the owner: `get set show path archive` (1a), `list` (1b), `import` (4a), `prune` (5) |
| `scripts/_filter_ready.py` | readiness on (normalised item, record, `ready:` policy) |
| `adapters/*/{set-status,assign,me}.sh` (new) | native status, assignment, the flow's own user |
| `scripts/_health.py drift`, `lib/drift.sh` (new) | pure classifier to repair codes; one repair per code |
| console `collectors/records.ts` (new) | reads records; `reconcile.ts` takes flow facts from them only |

## Seams
- flow and record: `lib/state.sh` only. The console reads the JSON, so schema `v` is a published contract.
- flow and tracker: `adapter <op>` (`lib/flow.sh:373-382`). Ops after 4b: list, list-ready, read, create, close, comment, link-pr, set-status, assign, me; optional vocabulary, answers.
- record and tracker meet in three places: the mirror inside `record_set` (until 4b), `tracker_push` (record to tracker) and health drift (compare).

## 1. The flow record

Layout
- `state.dir`: `cfg state.dir` (absolute, or relative to the main worktree), default `<flow home>/state`. Per machine by default, since the flow home is the main worktree's `.flow` (`lib/flow.sh:76-81`); already ignored (init excludes `.flow/`). A `state.dir` that cannot be created or written exits 2 before anything is written.
- `<state.dir>/<slug>.json` open, `<state.dir>/closed/<slug>.json` archived. Locks in `<flow home>/locks/<slug>.lock`, never in `state.dir`.

Schema v1, final (`hold`, `gate`, `answer`, `pr`, `claim`, `run`, `pushed` are null when absent; lists are `[]`, never null)
```json
{"v":1,"item":"gh#73","step":"plan","profile":"task-M","size_estimate":"M","attempts":1,
 "touches":["src/a/**"],"changes":[],"base":"main","last_event":"...",
 "hold":{"by":"gh#70","reason":"..."},
 "gate":{"name":"ambiguity","from":"design","message":"...","time":"...","host":"claude",
         "options":[{"label":"...","text":"...","recommended":true}],"raised_by":"step design",
         "answered_by":"step design","condition":null,"footer":"..."},
 "answer":{"gate":"plan-approval","asked":"...","text":"...","at":"...","pending":"next"},
 "pr":{"url":"...","host":"claude"},
 "claim":{"machine":"mbp","host":"claude","claimed_at":"...","assigned_at":"","worktree":"brain-wt-3"},
 "run":{"step":"plan","profile":"task-M","worktree":"/abs","reports":"/abs","host":"claude","started":"...","pid":123,"touches":[]},
 "pushed":null,
 "created_at":"...","updated_at":"..."}
```
`gate` keeps the names `notify.sh` writes (`message`, `time`, `host`, then `options`, `raised_by`, `answered_by`, `condition`, `footer`, ADR 0003) and `run` the fields `next.sh` writes, so each view is the object with `item` put back. `pushed` (`{"status","at"}`) and `claim.assigned_at` are slice 3's. The claim keeps the worktree's name only: its path and branch are in the worktree's `claim.json`, which stays the pointer (S-01).

Key map, final (the twenty, then the record's own)
| Today's key | Record path |
|---|---|
| step, profile, attempts, touches, changes, last_event, base | same name; `base` outlives the claim (`next.sh:170` reads it for a step with no worktree) |
| size | `size_estimate`; effective size is the estimate, else the tracker's size, else `default_size` |
| worktree | `claim.worktree`; a name on a null claim makes one with no machine; an empty value clears the name and keeps the hold |
| held_by, held_reason | `hold.by`, `hold.reason`; `hold` is null while `by` is empty |
| gate, gate_from | `gate.name` (`none` or empty: `gate` is null), `gate.from` |
| answered, asked, answer, answered_at, answer_pending | `answer.gate`, `.asked`, `.text`, `.at`, `.pending`; `asked` is only ever written with the answer (`lib/gate.sh:200-201`), the open gate's question is `gate.message` |
| pr, pr_host | `pr.url`, `pr.host` |
| record only | `gate.{message,time,host,options,raised_by,answered_by,condition,footer}`, `run.*`, `claim.{machine,host,claimed_at,assigned_at}`, `pushed.*` |

Shell API (`lib/state.sh`)
| Function | Slice | Does |
|---|---|---|
| `state_dir`, `record_file <item>` | 1a | paths |
| `record_get <item> <key>`, `record_show <item>` | 1a | read, no lock; a key is one of the twenty or a record path |
| `record_set <item> <pair>...` | 1a | the mirror, then create or merge under the lock, then the views the pairs name; a pair outside the grammar exits 2 |
| `take_item <item>` | 1a | this machine holds the item: `claim.machine`, `.host`, `.claimed_at` when the claim has no machine; slice 3 adds assign and push |
| `record_archive <item>` | 1a | to `closed/` |
| `item_read <id>`, `items_join` (stdin) | 1b | adapter item(s) with `state` joined from the record |
| `tracker_push <item>` | 3 | `set-status` from the record |
| `record_drop <item>` | 5 | delete, for the tidy |

`step_write` (`lib/flow.sh:397-414`) goes; its callers call `record_set`.

Locking
- Today `step_write` and advance.sh write under no lock; next.sh writes under `pick` (`scripts/next.sh:95,185`). The claim lock covers only worktree allocation (`scripts/steward.sh:200-205`), so the spec's "existing claim lock" cannot be the rule.
- Rule: every record write is one `_state.py` process: `flock` on the item's lock file, read, merge per key, write a temp file, rename. Readers never lock. The record lock is a leaf: nothing is taken under it, and no tracker call is made under it.
- Not `flow_lock`: it holds one lock per process and replaces the exit trap (`lib/flow.sh:162-178`); next.sh already holds `pick` there and a gate clear holds `gate-<slug>` (`lib/gate.sh:125-128`). Not `item:<slug>`: a comments pass holds it for a whole session (`jobs/comments.sh:338`).

Lifecycle
| Event | By | Effect |
|---|---|---|
| create | the first `record_set` or `take_item` (lazy seed), `import` | a record; an id no adapter owns gets none (`scripts/steward.sh:132`) |
| update | every writer, through `record_set` | merge, `updated_at` |
| archive | `steward.sh release` when the item reads closed, where its reports go today (`scripts/steward.sh:285-290`); health `closed` | move to `closed/`; refused when `claim.machine` is another machine's |
| delete | health tidy after `state.keep` (30d) in `closed/`; at once when the tracker answers no such item | never while a `claim.json` names the item |

Today's stores
| Store | Slices 1a to 6 | After 4b |
|---|---|---|
| `runs/<slug>.json` (`scripts/next.sh:179-180`) | view of `run`, written and removed by `_state.py` only when a write names `run` | deleted |
| `gates/<slug>.json` (`scripts/notify.sh:38`) | view of `gate`'s record fields; from 1a `notify.sh` hands its record to `record_set` and `_state.py` writes the file | deleted |
| `claim.json` `step` (`scripts/next.sh:166,211`, `lib/flow.sh:409-410`, `scripts/steward.sh:369-370`) | view, written by `_state.py` when a write names `step` or the run's step | key dropped; the file stays the pointer |
| `reports/<slug>/pr.json` | stays the pr step's result file; advance.sh copies the PR into the record at the end of a pr step (a fallback today, `scripts/advance.sh:52-56`) | same |
| `runs/.ready.$$`, `.notes.$$` (`scripts/next.sh:43,74`) | move to `<flow home>/tmp` in 1b | |

## 2. Normalised item and readiness

| Field | Wire | GitHub | Jira | local |
|---|---|---|---|---|
| open | `status`: open, closed (name kept) | issue state | `statusCategory` not done (`_jira.py:100`) | frontmatter `status` |
| category | `category`: todo, in-progress, review, blocked, done, unknown | closed: done. Else `project.status` (`_gh.sh:94`) back through `github.status`: backlog and ready: todo; running: in-progress; review: review; gate: blocked; a Status outside the map: blocked. No `github.project` or no card: unknown | category key new: todo; indeterminate: in-progress; done: done; a status named in `jira.status.review` or `jira.status.blocked` wins | new frontmatter `workflow` (the set-status name), same table; absent: unknown |
| assignee | `assignees`: list | logins, fetched at `_query.py:26` and dropped in `raw` (`:125`) | add `assignee` to `FIELDS` (`_jira.py:41`): email, else account id | frontmatter `assignee`, scalar or list |
| blockers, children | `blocked_by`, `open_blockers`, `open_children` | unchanged | unchanged | unchanged |
| size, priority, labels | same names | native; see open question 2 | field | field |

- `needs` and `rank` stay. Adapters stop testing `state.step` for `needs`; the filter applies it to unstarted items.
- `me.sh` prints what `me` stands for, one per line: the gh login (`github/list.sh:10-13`), the Jira account id and `jira.email` (`_jira.py:361`), the git email and name (`local/_item.py:173`).

Readiness (`_filter_ready.py`); held means the record has a `claim`
| Case | Ready when |
|---|---|
| always | open, no open blockers, no open children |
| held by this machine | no gate, step not split or done, no open hold past the plan, no live run. Category and assignee are not consulted: the flow set them |
| held by another machine (shared `state.dir`) | never; note `elsewhere` |
| not held | no `needs` while unstarted; `category` in `ready.categories`; assignees match `ready.assignee`; the record's gate and step as above when a record exists |

Notes gain `status`, `assigned` and `elsewhere`, worded in `_pick.py`. next.sh checks the fresh read again, for a named item too.

```yaml
ready:
  needs: [priority]           # today
  priority_order: [P0, P1]    # today
  assignee: [none, me]        # default; none | me | any | <login>
  categories: [todo, unknown] # default; a subset of these two
pick:
  team:
    assignee: [alice, bob]    # a list; a single value still reads
```
`ready_rules` (`lib/flow.sh:262-282`) exports `READY_ASSIGNEE` and `READY_CATEGORIES` and refuses an unknown value, exit 2. `FLOW_PICK_ASSIGNEE` becomes comma-separated (`lib/flow.sh:357`); each adapter matches any of the names.

## 3. set-status and assign

| Op | Contract |
|---|---|
| `set-status <id> <backlog\|ready\|in-progress\|needs-you\|in-review>` | idempotent. Prints `<id> <native name>` when it moved something; nothing when already there or the tracker has no place for it. Exit 2 for another name, 1 when the tracker fails |
| `assign <id> <me\|none>` | idempotent; same exit codes |

| Adapter | set-status |
|---|---|
| GitHub | the project Status, through today's `github.status` keys (backlog, ready, running, gate, review; `_gh.sh:28`), one card, reusing the lookup at `_mutate.py:90-119`. Without `github.project`: a no-op, or the single label `github.claim_label` (opt-in, off): added for in-progress, removed otherwise, read back as category in-progress |
| Jira | the transition named in `jira.transitions.<name>` (as `done` today, `_jira.py:329-342`); unset: the first transition into the matching status category for ready and in-progress, else a no-op said once |
| local | frontmatter `workflow` |

Caller: `tracker_push` only. It derives the status from the record, the rule of `_mutate.py:76-87` moved to the flow: no claim: nothing; gate merge or step done: in-review; another gate: needs-you; else in-progress. A push that lands is recorded in `pushed`; one that fails warns, logs an event and never fails the step.

| When | Where | Status |
|---|---|---|
| take | `take_item`, from next.sh and `steward.sh claim` | `assign me` when `assignees` is empty (sets `claim.assigned_at`), then in-progress |
| gate raise | gate.sh raise | needs-you; the merge gate: in-review (the spec's "pr") |
| gate clear | gate.sh clear | in-progress |
| every step ran | advance.sh, `step=done` | in-review |
| close | the `close` op | none; set-status has no done |
| give back | health `orphan`, `reset` | ready, or backlog when the item has `needs`; `assign none` when the flow assigned |

Retired in slice 3: `github/sync.sh`, `project_sync` (`_gh.sh:32-38`), `sync` and `desired` in `_mutate.py`, the trigger at `github/write-state.sh:69`, the per-schedule loop at `jobs/next.sh:90`. `answers` takes the gated ids as arguments, from the records, in place of the tracker's gate label (`github/answers.sh:12-16`, `_jira.py:393-397`).

## 4. Removal and migration

`tracker_state` controls the mirror only
| Release | Default | Behaviour |
|---|---|---|
| slices 1a to 3 | `labels` | `record_set` sends its state pairs to `adapter write-state` first; a tracker that refuses them fails the write and nothing is recorded |
| 4a | `none` | no mirror; `labels` keeps it, the tracker staying a second store every write must reach, for a team whose machines upgrade at different times |
| 4b, one release later | key gone | `write-state.sh` deleted |

Lazy seed, 1a to 4a: an item with no record reads with the tracker's `state` as is, and counts as held by this machine when that state has a step (it was started before the records). Creating its record copies in that state and, on this machine, the item's gate file and run file, at the cost of one tracker read, once per item. Once a record exists it wins; the two are never compared.

4a
- `state.sh import [--dry-run] [--strip]`: every open item with tracker state and no record gets one. `claim` only when a local `claim.json` names the item; a `wt:` label for a worktree not on this machine is skipped and said. It pushes status and assignee for each held item. `--strip` then removes the `step:`, `gate:`, `wt:` and `flow:` labels and the state comment, property or frontmatter keys, through a temporary `strip-state.sh` per adapter.
- Health says once how many items still carry flow labels.
- Size: next.sh stops writing the size at start (`scripts/next.sh:181-184`); a re-size writes `size_estimate` and a plain comment, never the tracker (`scripts/advance.sh:174`).
- Profile: pinned at first start (`scripts/next.sh:109-110`). `next.sh <item> --profile X` writes it: X must be a profile, and on a started item its step must be one of X's steps, else exit 2. `flow:plan --profile X` passes it through. The `flow:` label stops being read (`_gh.sh:64`, `profiles.json` `_readme`).
- `link-pr.sh` in each adapter drops its state write (`github/link-pr.sh:8`, `jira/link-pr.sh:7`, `local/link-pr.sh:7`): the comment and the Jira remote link stay. `pr.host` then needs a source that is not the tracker: the host the run was started on, which `run-unattended.sh` knows.

4b: delete `write-state.sh` and `strip-state.sh` in each adapter, the label, comment and property code (`_gh.sh:54-68,102-126`, `_query.py:103-122`, `flow_state` at `_jira.py:80`, `STATE_KEYS` at `local/_item.py:29`), `state` from the item contract and from `shape()` (`tests/adapter-contract.sh:52`), the fakes' label handling, the mirror, the seed and the three views.

## 5. Health repair table

`_health.py drift` reads the open items, the records, the pool's `claim.json` files and this machine's `events.log`, and prints `code<TAB>item<TAB>worktree<TAB>detail`. `lib/drift.sh` applies one repair per line through `health_say`, so each is an `events.log` line and `--dry-run` holds.

| Tracker | Record, worktree | Code | Repair |
|---|---|---|---|
| closed or done | record open | `closed` | release the worktree unless dirty; archive |
| in-progress, me | mine, run alive | `ok` | none |
| in-progress, me | mine, run dead | `resume` | today's `health_resume` |
| in-progress, me | none here, none shared; this machine's `events.log` shows its own take with no release | `orphan` | set-status ready; `assign none` when that take assigned; fact `orphan` |
| in-progress, me | none here, no such evidence | `held-elsewhere` | none; fact `held elsewhere`, said once |
| in-progress, someone else | none here | `held-elsewhere` | the same |
| todo or unknown, and unassigned, after a push or the flow's own assign landed | mine, claim held | `reset` | stop the run, release unless dirty, `claim` to null, record kept |
| any | mine; `pushed` differs from the derived status, or the assign did not land | `push` | push again |
| any | a `claim.json` names an item an adapter owns, no record | `rebuild` | a record from the claim; step unknown, so the profile's plan step runs again, its first step when it has no plan |
| any | `claim.worktree` differs from the worktree's `claim.json` | `stale-claim` | drop the record's worktree |
| gate open | a newer `/answer` | `answered` | today's `answers` path |

Tidy: drop `closed/` records older than `state.keep`; drop a record whose item the tracker no longer knows.

## 6. Console
Paths under `plugins/console/app/daemon/src`; lines as of console 0.19.1.
- `collectors/records.ts` resolves `state.dir` as `lib/state.sh` does and reads the records. It replaces the reads of `gates/`, `runs/` and the claim's step (`collectors/flowHome.ts:449-461`).
- `reconcile.ts`: step, gate, worktree, pr, last event, hold and answer come from the record. The precedence at `:326` and the disagreements at `:763`, `:797` and `:809` go. `BoardItem.state` (`collectors/board.ts:27-30`) goes; `category` and `assignees` arrive.
- `item.step-sync` goes: `actionPlan.ts:834`, `stepSync.test.ts`, its UI row.
- `plugins/flow/schema.ts` (the console's settings schema): `state.dir`, `state.keep`, `ready.assignee`, `ready.categories`, `pick.<name>.assignee` as a list (`:357`), `jira.status`, `jira.transitions.*`, `github.claim_label`, `tracker_state`; new help for `github.status` (`:190`).
- A plugin with no records shows the tracker's facts and a notice; no second read path stays (as fields of older plugins read absent today, `collectors/flowHome.ts:132`).

## 7. Deferred
`state.branch`: a tracked `state.dir` committed on its own branch. Nothing above depends on it; per-item files and atomic renames are what it needs.

## Slices

Order: 1a (gh#180), 1b (gh#176), 2 (gh#181), 3 (gh#177), 4a (gh#182), 5 (gh#178), 6 (gh#179), 4b (gh#183). One tracker task each. Every slice adds a changelog fragment (ADR 0002); 4a and 4b are `bump: major` (the default behaviour, then the adapter contract, change). Lines in slices 1b to 6 are as of 1.36.0 unless this file refreshed them.

**1a. The record and its writers** (defines the architecture)
- Goal: every flow write lands in the record; the tracker gets the same write first.
- Changes, order and proof: "Slice 1a build" below.
- Publishes: schema v1, the key map, the `record_set` grammar and exit codes, the view rule, `lib/state.sh` (`state_dir record_file record_get record_show record_set take_item record_archive`), `state.sh get|set|show|path|archive`, `state.dir`, `tracker_state`, `FLOW_MACHINE`.
- Compat: mirror on and required; no reader changes; a view is written only by the write that names its fact, so hand-made run and gate fixtures survive.

**1b. Readers and fixtures**
- Goal: every flow read comes from the record.
- Changes: `adapter read` with `state_get` becomes `item_read` in next, advance, gate, hold, steward (`:339`, `:611`, `:849-853`), `verify.sh:60-61`, `scripts/comments.sh:64`, `jobs/comments.sh:86,122,170-184,222`; `filter-ready.sh` joins before it filters; `_pick.py`, `_board.py`, `_health.py`, `_graph.py` and `board.sh:60` read records; `steward.sh pool` takes its step column from the record; `state.sh list`. The reads of run and gate files left by 1a move to the record: `advance.sh:29-32`, `next.sh:146-147`, `hold.sh:40`, `lib/gate.sh:78`, `gate.sh:67,102,181,206`, `steward.sh:359,627,728,848,853,1095,1106,1129,1453`, `run-unattended.sh:116`, `_gates.py`. The advice at `next.sh:147` (delete the run file) becomes `steward.sh stop`, and health clears from the record a run whose process is gone, since a run file removed by hand under 1a leaves one.
- Publishes: no flow script reads flow state from an adapter.
- Compat: mirror still on; `board.sh --json` keeps `state`, so the console is untouched.
- Touches: `plugins/flow/scripts/**`, `plugins/flow/jobs/{comments,health,next}.sh`, `plugins/flow/lib/{state,blockers,gate}.sh`, `plugins/flow/templates/run-unattended.sh`, `plugins/flow/evals/board-shows-state/**`, `plugins/flow/tests/{run,holds,blockers}.sh`.
- Proof: run.sh, holds.sh, blockers.sh with fixtures renamed from `adapters/<x>/write-state.sh` to `scripts/state.sh set` and from `read.sh | jget state.*` to `state.sh get`. Same grammar and the mirror keeps both stores equal, so a red test is a real bug. The adapters' own write-state tests stay until 4b.

**2. Normalised item and readiness**
- Goal: readiness obeys category and assignees.
- Changes: list and read of the three adapters, `me.sh`, `_filter_ready.py`, `ready_rules`, `pick_filter`, next.sh's re-check, `_pick.py` wording, `adapters/README.md`.
- Publishes: `category`, `assignees`, `me`, `ready.assignee`, `ready.categories`, list-valued `pick.<name>.assignee`.
- Compat: the defaults keep every unassigned item with no board ready; a held item is judged by its record, and an item started before the records counts as held (lazy seed), so work in flight keeps running.
- Touches: `plugins/flow/adapters/**`, `plugins/flow/scripts/{_filter_ready.py,filter-ready.sh,_pick.py,next.sh}`, `plugins/flow/lib/flow.sh`, `plugins/flow/skills/{next,init}/**`, `plugins/flow/tests/{adapter-contract.sh,_fake_gh.py,_fake_jira.py,readiness.sh,run.sh}`.
- Proof: adapter-contract.sh (the new fields and `me`, per adapter on its fake); new `tests/readiness.sh`.

**3. Native writes**
- Goal: the flow sets status and assignee itself; `sync` retires.
- Changes: `set-status.sh` and `assign.sh` in each adapter, `tracker_push`, `take_item`, the callers of section 3, `answers` by id, `github.claim_label`, the retire list.
- Publishes: the two ops, `pushed`, `claim.assigned_at`, `jira.status`, `jira.transitions.*`.
- Compat: the mirror still writes labels; a card moves once, from `tracker_push`, because `write-state.sh:69` goes here.
- Touches: `plugins/flow/adapters/**`, `plugins/flow/lib/state.sh`, `plugins/flow/scripts/{_state.py,_state_schema.py,next.sh,gate.sh,advance.sh,steward.sh}`, `plugins/flow/jobs/next.sh`, `plugins/flow/skills/init/**`, `plugins/flow/tests/{adapter-contract.sh,_fake_gh.py,_fake_jira.py,status.sh,run.sh}`.
- Proof: adapter-contract.sh (both ops on three adapters); new `tests/status.sh`; the sync checks in `tests/run.sh` rewritten.

**4a. Stop writing the tracker; import**
- Goal: no flow label, comment or size write; items in flight carry over.
- Changes: section 4, 4a. The checks that a tracker failure fails a flow write (`tests/run.sh:2143-2156`) are re-specified here: with no mirror nothing fails.
- Publishes: `state.sh import`, `--profile`, `tracker_state: none` as the default.
- Compat: lazy seed and `tracker_state: labels` for one release; adapters keep `write-state.sh`.
- Touches: `plugins/flow/scripts/{_state.py,_state_schema.py,state.sh,next.sh,advance.sh,steward.sh}`, `plugins/flow/lib/state.sh`, `plugins/flow/adapters/*/{link-pr,strip-state}.sh`, `plugins/flow/adapters/{github/_gh.sh,jira/_jira.py,local/_item.py,README.md}`, `plugins/flow/profiles.json`, `plugins/flow/skills/{next,plan,init}/**`, `plugins/flow/agents/pr-creator.md` and its Codex twin, `plugins/flow/tests/{migrate,run,adapter-contract}.sh`.
- Proof: new `tests/migrate.sh` (import, strip, seed, `labels` keeps the mirror); run.sh checks on labels after flow ops move to records.

**5. Health drift**
- Goal: every disagreement between tracker, record and worktree has one repair.
- Changes: `_health.py drift`, `lib/drift.sh`, a call and the tidy in `cmd_health` (`scripts/steward.sh:1363`), `record_drop`, `state.sh prune`.
- Publishes: the repair codes, the facts `orphan` and `held elsewhere`, `state.keep`.
- Compat: `--dry-run` first; existing health checks untouched.
- Touches: `plugins/flow/scripts/{steward.sh,_health.py,_state.py,state.sh}`, `plugins/flow/lib/{drift,state}.sh`, `plugins/flow/jobs/health.sh`, `plugins/flow/skills/steward/SKILL.md`, `plugins/flow/tests/{drift,run}.sh`.
- Proof: new `tests/drift.sh` on the local adapter: one check per row, the person played by editing frontmatter, the other machine by `FLOW_MACHINE`.

**6. Console**
- Goal: the console reads flow facts from the record only.
- Changes: section 6.
- Publishes: nothing to later flow slices; it frees 4b to delete the views.
- Compat: reads records when the plugin writes them; the read path may land any time after 1b, the settings keys after 4a (split 6a, 6b when it helps).
- Touches: `plugins/console/app/daemon/src/**`, `plugins/console/app/daemon/test/**`, `plugins/console/app/ui/{src,test}/**`, `plugins/console/app/README.md`.
- Proof: daemon tests (`reconcile`, `actionPlan`, `board`, `flowHome`, `flowConfig`; `stepSync` deleted) and the UI suite, `npm run check`.

**4b. Delete the compat layer**
- Goal: no code reads or writes flow state on a tracker. Lands one release after 4a and after 6.
- Changes: section 4, 4b.
- Publishes: the final adapter contract in `adapters/README.md`.
- Compat: none left; `state.sh import --strip` is the way in from an older release, so it ships in 4a and is said in the 4b changelog.
- Touches: `plugins/flow/adapters/**`, `plugins/flow/scripts/{_state.py,_state_schema.py}`, `plugins/flow/lib/state.sh`, `plugins/flow/tests/{adapter-contract.sh,_fake_gh.py,_fake_jira.py,run.sh}`.
- Proof: adapter-contract.sh with no `state` in `shape()`; run.sh without the write-state sections.

Edges
| Edge | Why |
|---|---|
| 1a to 1b | the API |
| 1b to 2 | the filter joins records |
| 2 to 3 | assign-when-unassigned needs `assignees`; `claim_label` reads as a category |
| 3 to 4a | `github/write-state.sh:69` is what calls `sync.sh`; cards must move by `set-status` before the mirror stops |
| 4a to 5 | drift compares against records that are the only source |
| 1b, 4a to 6 | records to read; keys to show |
| 6, a release to 4b | the console stops reading the views; old plugins stop reading labels |

Size (N-01): `steward.sh` (1562 lines), `lib/flow.sh` (523) and `tests/run.sh` (3907) are over the signal before any slice. No slice moves their existing code (U-05); new logic lands in `lib/state.sh`, `lib/drift.sh`, `_state.py`, `_state_schema.py` and `_health.py`, and new behaviour is tested in new suite files.

## Decisions where the spec left a choice
| Decision | Reason |
|---|---|
| `state` stays the read shape, joined by the flow | 41 `state_get` calls, the Python readers and the console keep one shape; slices stay green |
| the twenty flat keys stay the write grammar | callers and the 93 `write-state` references in run.sh, holds.sh, blockers.sh and base-readers.sh migrate by rename |
| `gate` (open) and `answer` (last cleared) are two objects | today's keys keep the answer after `gate=none` (`lib/gate.sh:200-201`) |
| the gate record of ADR 0003 is `gate`'s own fields, under `notify.sh`'s names | one gate, one object; the view is that object, so the console and `gate.sh list` read what they read |
| `base` is a top-level key | it must outlive a release, which clears the claim's worktree |
| while the mirror is on, the tracker write goes first and must land | `tests/run.sh:2143-2156` (a tracker that refuses the write keeps the gate, its record and the claim) passes unedited only so; callers' `\|\| die` keep their meaning |
| the lock is a `flock` inside `_state.py` | see Locking |
| `runs/`, `gates/`, claim step are views, then deleted | the console reads them until slice 6 |
| a view is written by the write that names its fact, from that write | fixtures made and removed by hand survive; a stale record field never re-creates a file |
| `pr.json` stays a result file; `link-pr.sh` is never a record writer | a worker's sandbox cannot write `state.dir` (`lib/host.sh:58`); the orchestrator copies |
| `open` keeps the wire name `status` | 17 flow readers and the console; no gain from the rename |
| `me` is an adapter op | three private lookups become one contract |
| local workflow status is a new key `workflow` | `status` gates `open_children`, `needs` and pick (`local/_item.py:123,139-140,200`) |
| set-status names map onto today's `github.status` keys | no config migrates; the spec's `set-status todo` is `ready` |
| one caller, `tracker_push`, derives the status | the GitHub-only rule becomes every tracker's |
| a Status outside the map reads blocked | a column the flow does not know is a person's |
| a named item obeys the policy too | the tracker is the coordination channel |
| `orphan` needs this machine's own take in `events.log` | with per-machine state and one account, another machine's hold looks the same; the spec's row would release it |
| the hold is `claim`; its worktree is optional | epics and split parents hold no worktree; a release clears the worktree, not the hold |
| the claim records the worktree's name, not its path or branch | the worktree's `claim.json` holds both and stays the pointer (S-01) |
| `claim.machine` is `FLOW_MACHINE`, else `hostname -s` | tests need a second machine |
| `tracker_state` defaults `labels`, then `none`, then goes | one knob over three releases |
| console: no second read path for old plugins | a notice costs less than two precedence rules |

## Rejected approaches
| Approach | Reason |
|---|---|
| explicit two-store API, no `state` on items | 41 `state_get` calls, the console contract and the `state.` lines of run.sh change in one slice; no green step between |
| keep `adapter write-state`, routed to a shared store | the contract would still name a flow op no adapter owns |
| shadow-write in 1a, files still written by each script | two writers per fact until 1b |
| record first, a failed mirror only warns | the gate file would go and the sweep would close the item while the tracker still shows the gate; `tests/run.sh:2143-2156` fails |
| the mirror run by `_state.py` under the item lock | the lock would be held across a network call, and `write-state` would have a second caller |
| a `_state.py` check pass before the mirror, so one write may mix state and record pairs | a second Python start on every write; no caller needs the mix |
| `link-pr.sh` calls `record_set` | the pr step's worker runs it in a sandbox that cannot write `state.dir`; an adapter would call up into the flow (A-01) |
| record lock through `flow_lock` | one lock per process (`lib/flow.sh:162-178`) |
| every write re-renders all views from the record | a run or gate file removed by hand would come back |
| status pushed on every record write | one or two GraphQL calls per step write |
| `status` widened to hold the workflow value on local | breaks every `status == open` test |

## Risks
| Risk | Mitigation |
|---|---|
| record and tracker differ in slices 1a to 3 | the tracker write goes first and must land; the same pairs go to both; a parity check in `tests/state.sh`; existing suites run unedited in 1a |
| a failed push read as a person's reset | `pushed`; health pushes again before it judges `reset` |
| two machines, one account, per-machine state | `orphan` needs local evidence; else `held elsewhere` |
| machines on mixed plugin versions | `tracker_state: labels`; `--strip` only once all upgraded; 4b a release later |
| a worker's sandbox cannot write `state.dir` | only orchestrator scripts write records; workers write result files and call `link-pr.sh`, as today |
| Jira workflows differ | set-status no-ops with one note when no transition fits; the category read does not depend on it |
| a synced `state.dir` holds a partial file | atomic rename; a writer refuses a record that does not parse (exit 1), a reader skips it and says so, as `gate.sh:66-75` does |
| the fakes hard-code labels | they gain assignees, assign and label edits in 2 and 3; label state goes in 4b |

## Open questions for the owner
1. A re-size at a step boundary re-selects the profile today (`scripts/advance.sh:171-185`). Does the pin stop that too? Recommended: no, the pin guards against a size edited on the tracker; the flow's own re-size still re-selects, as it did on gh#171.
2. With no size field, is a `size:` label still read? Recommended: yes, read-only, written by `create --size` and people, never by next or advance; else planned child tasks lose their size on repositories like this one (no `github.fields.size`).
3. `sync` also sorts the cards of unstarted items between Backlog and Ready, adding a card that is missing (`_mutate.py:85-87,112-115`). Drop it? Recommended: yes; the flow sets Status only on items it holds (adding their card when missing), and Backlog and Ready both read todo.

None changes the slices: 1 and 2 are a few lines in 4a, 3 a few in slice 3. The plan was approved with these recommendations standing. 1a adds one question, at the end of its build section.

Resolved from the exploration: `state.dir` is per machine by default; migration is `import` plus lazy seed; `github.claim_label` is opt-in, in slice 3.

## Slice 1a build

Read with section 1: its schema and key map are final for v1 and are not repeated here.

- Goal: every flow write lands in the item's record under a per-item lock; the tracker gets the same write first, so no reader and no test assertion changes.
- Non-goals: readers (1b), tracker ops, removing labels, `state.sh list|import|prune`, `state.keep`, the console.
- Done means: for an item driven only by flow scripts the record's twenty keys equal the tracker's `state`, and `runs/`, `gates/` and the claim's step hold what they held before.

### Contract

Settings
| Name | Value |
|---|---|
| `state.dir` | config key; absolute as given, relative under the main worktree (`dirname "$(flow_home)"`); unset: `<flow home>/state` |
| record file | `<state.dir>/<slug>.json`, archived `<state.dir>/closed/<slug>.json`; two-space JSON, keys in schema order, UTF-8 as is |
| lock file | `<flow home>/locks/<slug>.lock`, empty, never removed |
| `tracker_state` | config key; `labels` (default) or `none`; another value exits 2 (A-03). `none` is for tests in 1a: readers still read the tracker until 1b |
| `FLOW_MACHINE` | this machine's name in `claim.machine`; unset: `hostname -s`. For tests, like `FLOW_HOME` |

`record_set` grammar (`scripts/state.sh set` is the same call)
```
record_set <item> <pair>...
pair        = state-pair | record-pair
state-pair  = <key>=<text>          key: one of the twenty; a dash reads as an underscore
record-pair = run:=<object | null>  the run as next.sh shapes it (an "item" field is dropped)
            | run.step=<text>
            | gate:=<object>        the gate's record as notify.sh shapes it:
                                    {"gate": <name>, "item", "message", "time", "host", ...}
```
A key with a dot or a trailing colon is a record pair. One write holds state pairs or record pairs, never both (exit 2): only state pairs reach the tracker, and a refusal must leave both stores untouched.

Value rules, the adapters' own (`adapters/local/_item.py:245-261`), so both stores read the same
| Key | Rule |
|---|---|
| any text | taken as given, line breaks kept; an empty text clears the key |
| `attempts` | a whole number; empty is 0; anything else exits 2 |
| `touches`, `changes` | split on commas, blank items dropped, each kept as written; empty is `[]` |
| `gate` | `none` or empty: `gate` becomes null, whatever it held. A name: kept when it is the open gate's, else `gate` becomes `{name, from: ""}` |
| `gate_from` | sets `gate.from`; nothing while `gate` is null |
| `gate:=` | replaces every field of `gate` but `from` (kept when the name is the open gate's); `name` is the object's `gate`; a field of any JSON type is kept as given |
| `run:=`, `run.step=` | `run:=` replaces `run`; `run.step=` on a null run exits 2, nothing written |
| objects | `hold`, `pr`, `answer` and `claim` read null while every field is empty |

Pairs apply in the key map's order, not the caller's; a key given twice takes its last value. `record_set` returns its code and never exits its caller (unlike `adapter`, whose `die` does), prints nothing on stdout, changes no variable of its caller and never reads its caller's stdin (M-08, D-10): its own variables carry the prefix `flow_record_`, each adapter call runs in a subshell with stdin from `/dev/null`, and the seed reaches `_state.py` on a pipe.

One write, in order
1. Refuse, exit 2, in the shell: an id not of its adapter's shape (`item_id_shaped`; `record_get`, `record_show`, `record_archive` and `state.sh path` refuse it too), no pair, a pair with no `=`, state and record pairs together, `attempts` that is not a whole number, a `tracker_state` outside its two values, a `state.dir` that cannot be created or written (A-03).
2. Only with the mirror on and state pairs: `adapter write-state <item> <the pairs as given>`. Its failure ends the write with its exit code and nothing is written; its whitelist is the twenty (`github/write-state.sh:12`, `local/_item.py:29`, `_jira.py:37`), so a key outside them exits 2 there.
3. No record file yet: `adapter read <item>` is the seed; a read that fails seeds nothing.
4. A pair names `step`, `run.step` or a `run` that is not null: the claim file is `<steward.sh find <item>>/.flow/claim.json`, when there is one.
5. `_state.py set`, the write's one Python process: every pair checked against the grammar before anything is written (exit 2), then lock, load or seed, apply, `updated_at`, temp file, rename, the views the pairs name, unlock.

Exit codes
| Code | When | Written |
|---|---|---|
| 0 | done | the tracker (mirror on, state pairs), then the record, then the views |
| the adapter's code (1 as a rule) | the tracker refused the mirrored write; the adapter's own line is on stderr | nothing |
| 1 | the record does not parse or carries a `v` above 1 | the tracker, when step 2 ran; stderr names the keys |
| 2 | step 1; a key outside the twenty (the adapter's refusal, or `_state.py`'s with the mirror off); a record pair outside the grammar or its value rules | nothing |
| 75 | another write held the item's lock for 10 s | the tracker, when step 2 ran; stderr names the keys, and the same call again is safe |

So a non-zero exit means nothing was written, but for the two rows that say otherwise: a record that fails after the tracker took the write.

A caller's `|| die` or `|| echo` stays as written: it fires in the same cases as before, plus a record that cannot be written.

Views
| View | Shape | Written by a write that names | Removed by |
|---|---|---|---|
| `<flow home>/runs/<slug>.json` | `{"item", ...run}`: what `next.sh:179-180` wrote | `run:=<object>`, `run.step=` | `run:=null`, whether or not the record had a run |
| `<flow home>/gates/<slug>.json` | `{"gate": name, "item", ...the gate's record fields}`: what `notify.sh:30-38` wrote | `gate:=<object>` | `gate=none` or `gate=`, whether or not the record had a gate |
| `step` in `<worktree>/.flow/claim.json` | a string | `step=<s>`: `s`. `run:=<object>`, `run.step=`: the run's step, which wins when one write names both | never |

- A view is rendered from the write's pairs and the merged record, and only for a fact the write names. So `step=` leaves `runs/` and `gates/` alone; `gate=<name>` and `gate_from=` write no gate file (as today: the state is written at `gate.sh:149`, the file by `notify.sh` after the comment); `run:=null` does not touch the claim's step.
- So a file made or removed by hand stays as the hand left it until a flow write names its fact: the run fixtures at `tests/run.sh:2616-2626`, the gate fixtures at `:3190-3201`, `:3316-3317`, `:3522` and `:3718`, and the `rm -f .flow/runs/*.json` lines.
- Compact JSON as `json_obj` prints it, key order as given, through a temp file and a rename. The claim's step is written only when the claim file parses and names the item.

Lazy seed. With no record file, `_state.py` starts from `new_record` and applies, through the same key map (N-07): the item's `state` as the adapter read it; `<flow home>/gates/<slug>.json` when it parses as an object (its fields become the gate's record when the tracker shows no gate or the same one); `<flow home>/runs/<slug>.json` when it parses as an object; and `claim.machine` as this machine when the state has a step or a worktree. Then the write's pairs. The seed writes no view. A record that exists wins and is never compared with the tracker again. Of two first writes at once the second finds the record and drops its seed.

`take_item <item>`: under the lock, sets `claim.machine` (`flow_machine`), `claim.host` (`host_name`) and `claim.claimed_at` when the claim has no machine; nothing otherwise. Record only: no mirror, no view. Seeds like a write.

`record_archive <item>`: under the lock, moves the record to `closed/`, over an older one. Nothing, exit 0, with no record. Exit 1 and nothing moved when `claim.machine` names another machine. Views are left alone. A write after it starts a new record, seeded.

`record_get <item> <key>` prints as `json_get` does: a string raw, anything else as JSON, nothing when the item has no record or the path is absent, exit 0. One of the twenty reads through the key map (`gate` reads `none` when clear, `attempts` a number, `touches` a list); any other key is a record path (`gate.options.0.label`, `claim.machine`, `run`). `record_show <item>` prints the record, exit 1 with none. Neither seeds.

Lock. `fcntl.flock(LOCK_EX | LOCK_NB)` on the lock file, tried every 50 ms, 200 times (named constants; no clock is read), then exit 75. Held by `set`, `take` and `archive` only, for file work. Python 3.9, standard library only; no `flock` binary is used (macOS has none).

`_state.py` commands: `set`, `take`, `get`, `show`, `archive`. Every option is named and required (D-09): `--state-dir`, `--flow-home`, `--item`, `--now` and `--machine` (S-11: the clock and the machine arrive as arguments), `--host`, `--claim-file` (empty for none), `--seed stdin|none`; pairs follow `--`.

Standards the shape serves
- A-01, S-02: `_state_schema.py` reads no file, clock or environment and returns new records; `_state.py` is the edge.
- A-03: step 1 and the adapter's whitelist refuse a bad pair or config before any store is written; `set` checks every pair before it takes the lock.
- S-13, S-09, S-10: an unknown key, a busy lock and an unreadable record are returned values (a named `Outcome` of code and message) mapped to exit codes; exceptions are for broken invariants; no tuple crosses the two modules (`Pair`, `RecordPaths`, `Outcome` are named types with one constructor each, M-04, S-05).
- S-03, S-08: absence is a null object (`gate`, `hold`, `run`, `claim`, `pr`, `answer`), never a flag beside a value; lists are never null.
- D-10, N-06: no module-level mutable state; the schema version, lock wait and exit codes are named constants. The key map is one table, not a chain of branches (M-01).
- N-01: `_state_schema.py` and `_state.py` each stay under 300 lines, which is why they are two; siblings import as `adapters/github/_query.py:18` does, since `python3 -I` leaves the script's folder off the path.
- C-03: no item id in a script, a test name or a comment.

### Gaps decided
| Gap | Decision |
|---|---|
| `lib/gate.sh` (the clears moved there with gh#170) | a 1a writer: `:190` and `:247` (`step_write`), `:200` and `:261` (`adapter write-state`) become `record_set`. The `rm -f "$record"` at `:205`, `:251`, `:264` go: `gate=none` in the write above removed the view |
| `lib/base.sh:144` (gh#167) | `record_set`; a refused claim's `last_event` makes a record with a null claim |
| `link-pr.sh` in three adapters | untouched until 4a. The pr step's worker calls it in a sandbox that cannot write `state.dir` (`lib/host.sh:58`, `agents/pr-creator.md:46-49`), and its contract stays (`adapters/README.md:55`, `tests/adapter-contract.sh:228-231`). The orchestrator copies into the record: `advance.sh`, at the end of a pr step, the `pr` and `pr_host` the tracker then holds; `steward.sh:619`, the PR the sweep linked |
| `adapter write-state` only in `lib/state.sh` | the one call is `tracker_mirror`. Outside `adapters/` and `tests/` no file names `write-state` but `lib/state.sh`; inside `adapters/`, the three `write-state.sh` and the three `link-pr.sh` (local's calls `_item.py write-state`) |
| `skills/comments/SKILL.md:35` | becomes `"$P/scripts/state.sh" set <item> answer_pending=` now: a marker cleared past the record would be carried again once 1b reads the record |
| `templates/run-unattended.sh:97` | a writer of `run`: it ends one. Becomes `record_set "$item" "run:=null"`. It has no `write-state`; `:116` is a read and stays. An installed older copy still removes the file, leaving a `run` in the record that nothing reads before 1b |
| where `lib/state.sh` is sourced | once, in `lib/flow.sh` after `stamp.sh` (`:12`). `advance.sh`, `lib/gate.sh` and `lib/base.sh` all write and are reached from scripts that never name them; a per-script line can be missed and then fails only on that path. `lib/state.sh` defines functions and constants and runs nothing, so adapters and hooks that source `lib/flow.sh` pay a parse |
| `step_write` | deleted with its claim-step write; its ten callers call `record_set` |
| deleting a view | no script removes a run or gate file any more. It writes the fact (`run:=null`, `gate=none`) and `_state.py` removes the file in the same locked write, so record and view change together. A removal by hand (tests; the advice at `next.sh:147`) leaves `run` or `gate` behind in the record: nothing reads them before 1b, no write re-creates a file from them, and the next write of that fact replaces them |
| `notify.sh` (gh#170) | stays the writer of the gate's record (ADR 0003), through `record_set "$item" "gate:=$record"` in place of its own file write. Bare calls keep working (`tests/run.sh:724`, `:2807-2814`) |
| same order, same grouping | every edit replaces a call in place. Two writes are never merged: `next.sh` writes the run (record only, always lands) and then the state (mirrored, its failure ignored, as today), so a tracker failure at start still leaves the run that `advance.sh` needs |
| `steward.sh`, `tests/run.sh` size | no code moves. `write_state` keeps its name, its guard for ids no adapter owns (the worktree hook claims `adhoc:<name>`) and its warning; its body calls `record_set`. `run.sh` gains the four-line hook |
| `record_json` of the first design | named `record_show`: `lib/gate.sh` and `gate.sh` hold a variable `record_json` (N-04) |
| CLI | `get set show path archive`; `list`, `import` and `prune` land with their first user (D-04) |

### Edits
| Where | Change |
|---|---|
| `lib/state.sh` (new, about 130 lines) | `state_dir`, `record_file`, `tracker_state`, `flow_machine`, `record_get`, `record_show`, `record_set`, `take_item`, `record_archive`; private `state_python` (`python3 -I`), `tracker_mirror <item> <pair>...` (the one `adapter write-state` call, in a subshell), `record_claim_file`; each function small enough to stay under the complexity signal (M-01) |
| `scripts/_state_schema.py`, `scripts/_state.py`, `scripts/state.sh` (new) | as above; `state.sh` prints its header on bad usage, exit 2, as `gate.sh:220` does |
| `lib/flow.sh:12` | add `. "$FLOW_PLUGIN/lib/state.sh"` |
| `lib/flow.sh:397-414` | delete `step_write` |
| `lib/base.sh:144` | `record_set` |
| `lib/gate.sh:190,200,247,261` | `record_set`; the `\|\| die` at `:202` stays |
| `lib/gate.sh:205,251,264`, `scripts/gate.sh:112` | remove the `rm -f "$record"` |
| `scripts/gate.sh:110,149` | `record_set`; the `\|\| die` at `:111` stays |
| `scripts/gate.sh:155` | `record_set "$item" "run:=null"` |
| `scripts/notify.sh:37-38` | `record_set "$item" "gate:=$record" \|\| echo "flow: could not record the $gate gate of $item" >&2`; the notification goes on |
| `scripts/next.sh:165-166` | remove (the run write sets the claim's step) |
| `scripts/next.sh:179-180` | `take_item "$item"`, then `record_set "$item" "run:=$(json_obj ...the same fields...)"` |
| `scripts/next.sh:184` | `record_set` |
| `scripts/next.sh:211-212` | `record_set "$item" "run.step=sync"` |
| `scripts/advance.sh:52-56` | after the fallback (read the item again when it ran): when the tracker holds a `pr`, `record_set "$item" "pr=..." "pr_host=..."` with the tracker's two values |
| `scripts/advance.sh:58` | `finish_run() { record_set "$item" "run:=null" >/dev/null; }` |
| `scripts/advance.sh:73,130,153,174` and `:86,147,158,176,193,205,211,218` | `record_set` |
| `scripts/hold.sh:103,111` | `record_set`; both `\|\| die` stay |
| `jobs/comments.sh:188` | `record_set` |
| `templates/run-unattended.sh:97` | `record_set "$item" "run:=null"` |
| `scripts/steward.sh:130-135` | `write_state`'s body calls `record_set` |
| `scripts/steward.sh:178` | `take_item` for an id an adapter owns, before the `write_state` call, which is unchanged |
| `scripts/steward.sh:283`, `:347`, `:1478`, `:1535` | unchanged text (they call `write_state`) |
| `scripts/steward.sh:285-290` | `record_archive "$item"` in the closed-item block |
| `scripts/steward.sh:368-370` | `write_state "$sp_item" "step=split"`, only when the claim's step is not split yet (the write at `:347` set it when the item was not split before), so the tracker is written as often as today |
| `scripts/steward.sh:619` | after a link that landed: `write_state "$it" "pr=$pr"` |
| `scripts/steward.sh:870-871` | `record_set "$it" "run:=null"`, then `record_set` for `last_event` (two writes, as today) |
| `scripts/steward.sh:1225` | `record_set` |
| `scripts/steward.sh:1475`, `:1534` | `record_set <item> "run:=null"` |
| `skills/comments/SKILL.md:35` | `scripts/state.sh set` |
| `tests/state.sh` (new), `tests/run.sh` after `:486`, `tests/_base_fixture.sh:1-3` | the suite, its hook, the fixture's list of suites |

### Build order
Each step is one commit (W-01); one PR (W-02).
1. This file as `docs/design/flow-owns-its-state.md` and `docs/adr/0004-flow-owns-its-state.md`. Verify: `tools/lint.sh`.
2. `_state_schema.py`, `_state.py` without views, `lib/state.sh`, `scripts/state.sh`, the source line in `lib/flow.sh`, and `tests/state.sh` with its hook: keys, grammar, mirror, lock, seed from the tracker, take, archive. Nothing calls the module yet. Verify: `sh plugins/flow/tests/state.sh`; `sh plugins/flow/tests/run.sh` green; note the suite's time before and after.
3. The three views and the seed from the gate and run files. Verify: the view and seed checks of `tests/state.sh`.
4. The state-key writers: `advance.sh`, `hold.sh`, `lib/gate.sh` (`:190,200,247,261`), `gate.sh` (`:110,149`), `lib/base.sh`, `jobs/comments.sh`, `steward.sh` (`write_state`, `:871`, `:1225`), `next.sh:184`; delete `step_write`. Scripts still write and remove run and gate files themselves here, which is consistent: `gate=none` and their own `rm` remove the same file. Verify: `run.sh` green; `grep -rn 'write-state\|step_write' plugins/flow --include='*.sh' --include='*.py'` outside `adapters/` and `tests/` shows `lib/state.sh` only.
5. The run: `next.sh` (`:165-166`, `:179-180`, `:211-212`, `take_item`) and `run:=null` at `advance.sh:58`, `gate.sh:155`, `run-unattended.sh:97`, `steward.sh:870,1475,1534`. Verify: `run.sh` green; no `rm -f` of a run file is left in `scripts/`, `lib/`, `templates/` (the `.ready` and `.notes` caches of `next.sh` stay).
6. The gate's record: `notify.sh:37-38`; remove the four `rm -f "$record"`. Verify: `run.sh` green; no script writes or removes a file under `gates/`.
7. The claim and the PR: `steward.sh` (`:178`, `:285-290`, `:368-370`, `:619`), the pr copy in `advance.sh`. Verify: `run.sh` green; the parity and release checks of `tests/state.sh`.
8. `skills/comments/SKILL.md:35`, `adapters/README.md`, the headers of `notify.sh` and `gate.sh` where they say who writes the gate file, the changelog fragment. Verify: `tools/test.sh` green; `git diff main -- plugins/flow/tests/run.sh plugins/flow/tests/holds.sh plugins/flow/tests/blockers.sh` shows only the added hook.

### tests/state.sh
Seams
| Seam | Use |
|---|---|
| `tests/_base_fixture.sh` | offline `PATH`, `check`, `json_value`, `new_repo` (local adapter, three-worktree pool), `new_task`, `state <item> <key>` (the tracker's state), `run_file` |
| `scripts/state.sh` | the only way the suite writes or reads a record; it opens no file under `state.dir` and tests a path only for existence (`state.sh path`) |
| `adapters/local/write-state.sh`, `read.sh` | the tracker before the records (seed), and the mirror read back |
| `.flow/config.yaml` | `tracker_state: none`, a bad `tracker_state`, `state.dir` |
| `chmod a-w` on the item file | a tracker that refuses a write (as `tests/run.sh:2150`) |
| `FLOW_MACHINE` | the other machine |
| background jobs and `wait` | two writers at once |

Checks, one behaviour each, named `Scenario_Outcome: because ...` (T-09, T-11); outcomes only, never that a script was called (T-08); values a wrong answer shows (T-02)
- Keys: each of the twenty reads back what was set (one check per key, from a table of key and sample value); a comma list reads back as a list; an empty value clears; `attempts=` reads 0; `gate=none` reads `none`; a dash key reads as its underscore key; each gate record field (options, raised_by, answered_by, condition, footer, message, time, host) reads back after `gate:=`.
- Refusals: an unknown key, `attempts=x`, a `:=` value that is not JSON, a state pair beside a record pair and an id no adapter owns each exit 2 and leave the record and the tracker as they were.
- Mirror: with the default the tracker reads the value set; with `tracker_state: none` it does not; a tracker that refuses fails the write and records nothing; a record-only pair lands while the tracker refuses writes; a bad `tracker_state` exits 2.
- Lock: two writers of different keys in a loop of 25 rounds both hold their last value and the record parses; two first writes at once make one record with both.
- Views: `run:=` writes the run file with its fields; `run.step=` changes it; `run:=null` removes it, a hand-made one too; `step=` leaves a hand-made run file alone and does not bring back one removed by hand; `gate:=` writes the gate file with `notify.sh`'s fields; `gate=<name>` writes none; `gate=none` removes it; `last_event=` leaves a hand-made gate file alone; on a claimed item the claim's step follows `step=` and a run's step; an unclaimed item gets no claim file.
- Seed: the first write of an item started before the records copies the tracker's twenty keys; a gate file's options and a run file come with it; a started item is claimed for this machine; a later change on the tracker does not reach the record; `get` of an item with no record prints nothing.
- Take and archive: a `next.sh` start under `FLOW_MACHINE=alpha` records `claim.machine` alpha; archive moves the record to `closed/`; with no record it does nothing; a record another machine claims is refused and stays; releasing a closed item archives its record; a write after the archive starts a new record.
- Parity: after `next.sh`, a result file and `advance.sh`, then after a gate raise, then after its clear, the record's twenty keys equal the tracker's `state`.

Hook in `tests/run.sh`, after the base-claim block (`:483-486`), in its shape: run `state.sh`, check its exit code, print its `FAIL` lines.

### Docs
- `docs/design/flow-owns-its-state.md` (this file), `docs/adr/0004-flow-owns-its-state.md`.
- `plugins/flow/adapters/README.md`, after the state-keys paragraph (`:101-111`): flow scripts write state through `record_set` (`lib/state.sh`), which sends the same pairs to `write-state` while `tracker_state` is `labels`; `state.dir` and `tracker_state` in the Config section; at `:113-117` the gate's record is written by `notify.sh` through the flow record (ADR 0004). No link out of the plugin (the lint refuses one).
- `plugins/flow/skills/comments/SKILL.md:35`.
- Headers: `scripts/state.sh` (its usage), `scripts/notify.sh:8-9`.
- The init config template and the console's settings schema gain the two keys in 4a and 6, when an owner has a reason to set them.

### ADR 0004 (`docs/adr/0004-flow-owns-its-state.md`)
```markdown
# ADR 0004: the flow owns its state

Date: 2026-11-15. Status: accepted.

## Context
The flow kept an item's workflow state on its tracker (labels and a state comment, an issue
property or frontmatter; twenty keys through `write-state`) and in three local stores:
`claim.json`, `<flow home>/runs/` and `<flow home>/gates/` (ADR 0003). No store owned a fact, so
they could disagree, every issue carried flow vocabulary, and a step wrote under no lock.

## Decision
- One JSON record per item, `<state.dir>/<slug>.json` (default `<flow home>/state`), holds every
  workflow fact, the gate record of ADR 0003 included. `scripts/_state.py` is the only code that
  opens it; scripts go through `lib/state.sh` (`record_set <item> key=value...`, the twenty keys
  as before) and `scripts/state.sh`.
- Every record write is one process under a per-item `flock`: read, merge, temp file, rename.
  Readers take no lock.
- An adapter ends up reading and writing only what its tracker models: open, category, assignees,
  blockers, size, priority. Until the labels go, `record_set` sends each write to `write-state`
  first (`tracker_state: labels`, the default) and records it only when the tracker took it, and
  `runs/`, `gates/` and the claim's step are views `_state.py` writes when a write names their
  fact.
- Rejected: keeping `write-state` and routing it to a shared store (the adapter contract would
  still name an operation no tracker owns); a lock through `flow_lock` (one lock per process, and
  `next.sh` already holds `pick`); each script writing the record beside its old store (two
  writers per fact); recording first and only warning when the tracker refuses (the record and
  the labels people read would disagree).

## Consequences
- The record is per machine by default, as the gate record was: another machine sees an item's
  state only through the tracker's status and assignee, which later slices write natively.
- The record's schema (`v`) is a contract: the console reads the files.
- While the mirror is on, a tracker failure fails a flow write exactly as before.
- A worker in a sandbox cannot write `state.dir`: only orchestrator scripts write records, and a
  worker reports through its result file and `link-pr`.
```

### Changelog fragment (`plugins/flow/changelog.d/gh-180.md`)
```markdown
bump: minor

- Every flow write now lands in a flow-owned record, one JSON file per item under `state.dir`
  (default `<flow home>/state`; `closed/` holds the record of a closed item once its worktree is
  released), written under a per-item lock (gh#180, ADR 0004). `record_set` in `lib/state.sh`
  takes the twenty state keys as `write-state` does; `scripts/state.sh` is its command line
  (`get`, `set`, `show`, `path`, `archive`). The record also holds the gate's record (options,
  who raised it, who answers, condition, footer), the run in flight and the claim, with the
  machine that holds it (`FLOW_MACHINE`, default `hostname -s`).
- Nothing else changes yet. Each write goes to the tracker first (`tracker_state: labels`, the
  default) and is recorded only when the tracker took it, so a tracker failure fails a write as
  before. `<flow home>/runs/`, `<flow home>/gates/` and the claim's `step` are written from the
  record. `tracker_state: none` turns the mirror off; it is for the release whose readers use
  the record.
- An item started before this release gets its record on its first write, from the tracker's
  state and this machine's gate and run files.
- The comments skill clears a taken answer with `scripts/state.sh set <item> answer_pending=`.
  `.flow/run-unattended.sh` changed, so `flow:init` asks to be run again.
```

### Risks
| Risk | Mitigation |
|---|---|
| the tracker took a write and the record did not (lock busy for 10 s, a record that does not parse, disk full) | stderr names the keys; the same call again is safe; the round-trip check holds the adapters' whitelists and the key map to the same twenty |
| two writers of one key of one item at once: the mirror runs outside the lock, so the stores can keep different last writers | in practice `last_event`; gate clears already hold `gate-<slug>`; the record wins from 1b |
| a run or gate file removed by hand leaves `run` or `gate` in the record | nothing reads them before 1b; 1b's health clears a run whose process is gone and rewords `next.sh:147` |
| a hand `write-state.sh`, or a `link-pr.sh` outside a pr step, is not in the record | 1b moves the fixtures to `state.sh set`; 4a ends `link-pr`'s state write |
| suite time: every write adds one Python start (0.1 to 0.3 s on this machine), a step or run write one `steward.sh find`, each start and claim one `take_item` | one process per write by design (no check pass before the mirror); measure `run.sh` at build step 2 and say the change in the PR |
| a shell variable or the stdin of a caller's `while read` loop taken by `record_set` (`steward.sh:1222-1228` writes inside one; `adapter()` sets `name`, which `health_claim` uses) | the three rules under the grammar; a check in `tests/state.sh` that a loop around `state.sh set` keeps its input |
| `templates/run-unattended.sh` is in the install set | init asks for one more run; an older installed copy keeps working |
| a comments skill run by hand in a Codex sandbox cannot write `state.dir`, where GitHub's `write-state.sh` could write | `state.sh set` exits 2 saying so; the answer stays pending and the job carries it |
| PR size (W-03): about 700 lines of code and tests, plus this file | one concern; commits in the build order read one at a time; declared in the PR body |

### Question for the owner
1. Is "`adapter write-state` is called only from `lib/state.sh`" met while the three `link-pr.sh` still write `pr` and `pr_host` to their own tracker until 4a?
   Recommended: yes, the pr step's worker cannot write `state.dir`, section 4 already ends that write in 4a, and no flow script but `lib/state.sh` names `write-state`.

The build goes on with the recommended answer; a no moves the `link-pr` change of 4a into this slice and breaks `tests/adapter-contract.sh:228-231`.
