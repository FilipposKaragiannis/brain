# Tracker adapters

An adapter is the flow's one way into a tracker. Each is a folder here, `adapters/<name>/`, named
in the config (`adapters.default`, `adapters.epic|task|bug`). The flow never talks to a tracker
any other way: it runs the folder's scripts and reads the item JSON they print. This file is the
contract a folder must meet; `tests/adapter-contract.sh <name>` checks it against the adapter's
fake backend, and `tests/run.sh` runs it for every adapter.

## The folder

| File | Required | What it is |
|---|---|---|
| `prefix` | yes | one line: the id prefix the adapter owns (`gh#`, `local:`, `jira:`) |
| `slug.sed` | yes | a `sed -n` script that turns an item's slug back into its id, printing nothing for a slug it does not own |
| `list.sh`, `list-ready.sh`, `read.sh`, `in-scope.sh`, `create.sh`, `close.sh`, `comment.sh`, `link-pr.sh`, `write-state.sh` | yes | the operations below, executable |
| `sync.sh`, `vocabulary.sh`, `answers.sh` | no | the optional operations below; the flow checks for each before it runs it |

Every script sources `lib/flow.sh` (`. "$(dirname "$0")/../../lib/flow.sh"`) for `die`, `cfg`,
`flow_home` and the JSON helpers, and says what went wrong as one `flow: ...` line on stderr.

## Ids and routing

An id is the prefix and a non-empty rest, in the id characters `A-Za-z0-9:#/_.-` (`gh#12`,
`local:task/3`, `jira:WID-7`). No prefix may start another. `lib/flow.sh` routes by the prefix
files, so a new adapter needs no edit there: `adapter_for <id>` names the adapter whose prefix
starts the id, `adapter <op> <id|name> [args]` runs `adapters/<name>/<op>.sh`, and
`scripts/_filter_ready.py` reads the same files to look up a blocker, or the item `held_by` names,
in another tracker. A name `adapter` takes is a folder under `adapters/`, never a path: a first
argument no prefix owns that has a `/`, starts with a dot or names no folder there exits 2.
`item_id_shaped <id>` holds an id to its adapter's shape: the adapter owns it and its `slug.sed`
turns the id's slug back into the id, so a gate's `blocked_by:<id>` condition is never a path.

`item_slug` turns an id into a name safe for a branch and a folder (`tr ':/#' '---'`: `gh-12`,
`local-task-3`, `jira-WID-7`); task branches are `flow/<slug>`, reports live in
`.flow/reports/<slug>`, and a `claude --worktree <slug>` session claims for the item.
`slug_item <slug>` reverses it through each adapter's `slug.sed`, so the reverse must be unique:
`s/^gh-\([0-9][0-9]*\)$/gh#\1/p`.

`scripts/_slack.py` reads the prefix files too, to set ids as code and to say a gate is answered on
the tracker when the item's adapter has `answers.sh`; so does the console (`readAdapterPrefixes`),
to take an id in an action and route it to its adapter. Still named by hand: `scripts/steward.sh`
`item_id` checks the exact shape of `gh#` and `local:` ids and takes any other adapter's id by its
prefix.

## Operations

| Script | Arguments | Prints |
|---|---|---|
| `list` | `[--all] [--kind KIND]` | a JSON array of items: the open ones, every one with `--all`, one kind with `--kind` |
| `list-ready` | `[--kind KIND]` | the ready items, best first: `list` piped through `scripts/filter-ready.sh` |
| `read` | `<id>` | one item, whether or not it is inside the tracker's scope |
| `in-scope` | `<id>` | nothing; exit 0 when the item is inside `<name>.scope` or no scope is set (no tracker call), 1 when it is outside, 2 for a scope the checks refuse (Tracker scope, below); GitHub exits 3 when the tracker cannot answer, so a failed call never reads as outside |
| `create` | `<kind> <title> [--size S\|M\|L] [--priority NAME] [--area NAME] [--type NAME] [--blocked-by id,id] [--parent id] [--body TEXT]` | the new id, one line |
| `close` | `<id> [--comment TEXT]` | nothing; the item reads `closed` and the comment lands |
| `comment` | `<id> [--body TEXT]` | nothing; the text is `--body` or stdin |
| `link-pr` | `<id> <url>` | nothing; `state.pr` reads the url, `state.pr_host` the host that ran it (claude or codex, else unset), and a comment names it |
| `write-state` | `<id> key=value...` | nothing; each key reads back (below) |
| `sync` | `[id]` | optional: moves the tracker's own board to the flow state, one line per change; exit 0 with nothing to do. `jobs/next.sh` runs it each round. A tracker whose board shows the flow state already (Jira's labels) has none |
| `vocabulary` | | optional: `{"types": [...], "areas": [...]}`, the names a new item may use; the intake job reads it |
| `answers` | | optional: clears each gate the owner answered on the tracker (a comment after the gate's `**Gate: <gate>**` comment whose first word is `/answer`, by an owner the adapter trusts; never the merge gate) through `scripts/gate.sh clear`, prints each cleared id; `jobs/next.sh` runs it, and a Slack gate message says to answer on the issue |

`kind` is `epic`, `task` or `bug`. `create` puts a value the tracker has no place for nowhere
and says so on stderr (`--type` on a tracker without types, `--priority` without a field for it);
it never fails for one. `--blocked-by` may name items of other adapters. A tracker scope bounds
the list first (Tracker scope, below), and a tracker limit caps what is left. A `list` cut short by
a tracker limit says so on stderr, and fails when `FLOW_LIST_WHOLE` is set (the board graph needs
every item).

Exit codes, for every script:

| Code | When | stdout |
|---|---|---|
| 0 | done | as above |
| 1 | the tracker failed, or the item does not exist; for `in-scope`, also an item outside the scope | nothing |
| 2 | a usage error: a missing argument, an unknown option, an unknown state key, an id the adapter does not own | nothing |

A tracker reached over the network retries a 5xx answer or a dropped connection the way `gh()` in
`lib/flow.sh` does (waits from `FLOW_GH_RETRY_WAIT`, default `2 5`, then one last try), and tries
a call that creates something (an issue, a comment) once, because a lost answer can follow a write
that landed. The Jira adapter's waits come from `FLOW_JIRA_RETRY_WAIT`.

## The item

| Field | Type | |
|---|---|---|
| `id` | string | the prefix and the rest |
| `kind` | `epic`, `task`, `bug` | |
| `title`, `body` | string | the body is Markdown, the item shape |
| `status` | `open`, `closed` | |
| `size` | `S`, `M`, `L` or empty | the same value as `state.size` |
| `priority`, `area` | string, empty when unset | the tracker's own names |
| `labels` | list of strings | the tracker's labels, for the board |
| `blocked_by` | list of ids | |
| `parent` | id or empty | |
| `open_children` | number | open items whose parent this is; a parent with any is not ready |
| `url` | string | where the owner opens it (the file path for a local item) |
| `state` | object | the flow state, below |
| `open_blockers` | list of ids, optional | the open ones among `blocked_by`, when the adapter knows; without it `filter-ready` reads each blocker through its adapter |
| `rank` | number | lower is picked first: the priority's place in `READY_PRIORITY_ORDER`, the order's length for a priority not in it, 999 without one; `_filter_ready.py` and `_graph.py` sort on it |
| `needs` | list | the fields of `READY_NEEDS` an open item with no step yet lacks; an epic never needs a size. `_filter_ready.py` holds back an item with any |
| `type` | string, optional | the tracker's own issue type |

`state` always has `step`, `profile`, `size`, `worktree`, `last_event`, `pr` (strings),
`attempts` (a number), `touches` (a list of globs), `changes` (the globs among them whose existing
behavior the plan changes, a list), `held_by` (the item this one waits behind, empty when free),
`held_reason` (one line, why) and `gate` (`none` when clear), and, once written, `gate_from`,
`pr_host` (claude or codex, the host that wrote the PR), `base` (the branch the item's work starts
from and merges into, written at its claim; empty for claims made before the base was recorded),
`answered`, `asked`, `answer`, `answered_at` and `answer_pending` (`next` or `comments`, what
carries out the answer to a cleared gate; empty once a run took it). Those twenty are the state keys.
`write-state` takes them as `key=value` (a dash reads as an underscore): `touches` and `changes`
are comma-separated, `attempts` a whole number, an empty value clears a key, `gate=none` clears
the gate, `size` sets the item's size too. A key outside the twenty exits 2 and writes nothing.

A gate's own data is not tracker state: the options it offers, who raised it, who carries the
answer out, the condition it waits on and its footer live in the gate's record in the flow home,
`<flow home>/gates/<item>.json`, which `scripts/gate.sh raise` writes through `scripts/notify.sh`
and `gate.sh list` reads (ADR 0003). Of a waiting gate the tracker holds `gate` and `gate_from`
only, so an adapter stores no more for a gate than it did.

## Config

The flow reads `adapters.default` (default `local`) and `adapters.<kind>` to pick where a new
item goes. It lists from the trackers `adapters_configured` names: the config's `trackers`
(`trackers: [github, local]`) when set, each one an adapter folder here, else every adapter named
under `adapters.*` and `local`. An adapter reads its own keys under `<name>.*` and nothing else of
the config but the shared keys here. A token never sits in the
config: it comes from the environment, and an adapter without one refuses with a plain reason.

Readiness is tracker-neutral: `ready.needs` lists the fields, of `priority` and `size`, an
unstarted item must have before it is ready, and `ready.priority_order` ranks the priority names.
`list` and `read` call `ready_rules` from `lib/flow.sh` before they build items; it exports them
comma-separated as `READY_NEEDS` and `READY_PRIORITY_ORDER` (the deprecated `github.ready_needs`
and `github.priority_order` stand in for an unset key) and refuses a field it does not know, exit
2. The adapter fills `rank` and `needs` from those two and maps the fields to its own:

| Adapter | priority | size | state |
|---|---|---|---|
| `github` | the issue field `github.fields.priority` | the issue field `github.fields.size`, else the `size:<S>` label | labels `step:<step>`, `gate:<gate>`, `wt:<worktree>`, `flow:<profile>`, `size:<size>` (not with a size field), and the whole state as JSON in one issue comment marked `<!-- flow:state -->`; a label wins over the comment on read; an empty value or `gate=none` removes the label |
| `local` | the item file's `priority` | the item file's `size` | the item file's frontmatter, one key each |
| `jira` | Jira's own priority field | the field `jira.fields.size` (an id or a name), else the `size:<S>` label | the same labels as `github`, and the whole state as JSON in the issue property `flow-state`; a label wins over the property on read |

Until `ready_rules` and `trackers` land in `lib/flow.sh`, the GitHub adapter reads only
`github.ready_needs` and `github.priority_order`, the local adapter fills no `rank` or `needs`,
and the flow reads every adapter named under `adapters.*`. The contract suite follows
`lib/flow.sh`: with `ready_rules` there, `rank` and `needs` are required and every adapter must
pass the readiness checks; without it, an adapter whose items carry no `needs` skips them.

### Jira

The `jira` adapter reaches Jira Cloud through its REST API v3 with `curl`. Name it in
`adapters.default` or `adapters.<kind>`, and in `trackers` when that is set. Its keys:

| Key | Default | |
|---|---|---|
| `jira.site` | | required: `https://<org>.atlassian.net` |
| `jira.project` | | required: the project key, `WID` |
| `jira.email` | | required: the login the token belongs to |
| `jira.types.epic`, `.task`, `.bug` | `Epic`, `Task`, `Bug` | the issue type each kind is created as and read back from; any other type reads as a task |
| `jira.fields.size`, `jira.fields.area` | unset | a custom field, by id (`customfield_10040`) or name, for the size and the area; unset, the size is a label and the area is not kept |
| `jira.transitions.done` | the first transition named `Done` | the transition `close` takes |
| `jira.limit` | `500` | the most issues `list` reads, inside `jira.scope` |
| `jira.scope` | unset | the issues every search keeps (Tracker scope, below) |
| `jira.answer_from` | the token's user | the account ids or emails whose `/answer` comments clear a gate |

The token is `JIRA_API_TOKEN` in the environment, never a config key; without it every script
refuses before it calls Jira. It reaches `curl` on stdin, never on its command line. The
scheduled jobs run in a login `zsh`, so export it in `~/.zprofile` or `~/.zshenv`; the console
passes its own environment's token to the scripts it runs. Ids are
`jira:<KEY>-<n>`. A Jira blocker is a Blocks link; a blocker in another tracker, or a Jira one
whose link Jira refused, is a `Blocked by: <id>, <id>` line in the description, and then the item
carries no `open_blockers`.
`link-pr` adds the PR as a remote link and a comment.

`answers` reads the comments of each open issue at a gate (`GET .../issue/<KEY>/comment`) and
takes an `/answer` by the token's own user (`GET /rest/api/3/myself`) or by an account id or email
in `jira.answer_from`; Jira's REST API has no reactions, so the `Gate cleared: ...` comment
`gate.sh` writes is the receipt. `vocabulary` lists the project's issue types without sub-tasks
(`GET /rest/api/3/project/<KEY>`) and, for a `jira.fields.area` field of options, the values a new
task may pick (`GET /rest/api/3/issue/createmeta/<KEY>/issuetypes/<id>`); a free-text area field
has none. There is no `sync`: GitHub's moves a card on a Projects board, a second place that does
not follow the issue, while a Jira board's columns are the issues' own workflow statuses, whose
transitions each project shapes (with screens and conditions) and which no flow key maps. The flow
state shows on the card as the `step:` and `gate:` labels, which a board's quick filters and
swimlanes can use, and `close` takes the item to Done.

## Where the two adapters differed

| What | Before | The contract |
|---|---|---|
| a malformed or foreign id | local exited 1; GitHub's `die` ran in a command substitution, so the script went on and exited 1 | exit 2; both fixed |
| an unknown state key | local refused it; GitHub stored it in the state comment | exit 2, nothing written; GitHub fixed |
| `create --type` | `scripts/new.sh` passes it to any adapter; local failed on it as an unknown option | taken, left out where the tracker has no types; local fixed |
| an unknown `list` option | local ignored it | exit 2; local fixed |
| `rank`, `needs` | GitHub prints them, local does not | required, from `ready_rules` |
| `open_blockers` | GitHub prints it, local does not | optional, as above |
| a missing item on `write-state`, `comment`, `close` | local ends in a Python traceback, exit 1 | non-zero is the contract; the traceback is left as it is |
| extras | GitHub `list --limit N`, local `create --labels a,b` | the adapter's own; the flow never passes them |

## Fakes in tests

The contract suite and `tests/run.sh` never reach a tracker. A fake backend stands in for the
adapter's client on `PATH` (`tests/fake-gh.sh` and `tests/_fake_gh.py` for `gh`,
`tests/fake-jira.sh` and `tests/_fake_jira.py` for Jira's `curl`) and must:

- keep its store in a file under the test's temp folder, seeded with what the test needs;
- answer every call the adapter makes, in the shape the real service answers, and fail any other
  call with exit 1 and a `fake ...: unknown ...` line, so a new call cannot pass unseen;
- let the test read an item's comments as the tracker holds them;
- for a network tracker, fail the next N calls with a 5xx message on request (`fake-gh.sh` reads
  `$FAKE_GH_DIR/fail`), so the retries are tested.

The suite's setup for an adapter is a few functions in `tests/adapter-contract.sh`: `setup_<name>`
puts the fake on `PATH`, `config_<name>` prints the adapter's config block, `missing_<name>` an id
it owns that names no item, `comments_<name> <id>` the comments, and `blip_<name>` (network only)
the failing call.

## A new adapter

1. `adapters/<name>/` with `prefix`, `slug.sed` and the nine scripts; the optional ones when the
   tracker has a board, a type list or a place for the owner's answers.
2. Its keys under `<name>.*`, commented in the config `skills/init/scripts/init.sh` writes, and
   the name in the console's `ADAPTERS` (`plugins/console/app/daemon/src/plugins/flow/schema.ts`).
3. A fake of its client in `tests/`, its setup in `tests/adapter-contract.sh`, and its name in the
   contract loop of `tests/run.sh`.

## Pick filters

A pick filter narrows the ready list `next --pick <name>` takes (and a next schedule with
`--pick <name>` in its args). The config names each filter under `pick.<name>`:

```yaml
pick:
  mine:
    assignee: me              # me, a login or an email
    status: [To Do]           # the item's status in its tracker, any of these
    labels: [api]             # any of these
    kinds: [task, bug]        # any of epic, task and bug
    trackers: [jira]          # the trackers next reads for it; unset, every one it reads
  backend:
    query: 'component = Backend AND sprint in openSprints()'
    trackers: [jira]          # a query goes to exactly one tracker
```

`list` and `list-ready` take `--pick <name>`; `list-ready` passes it to `list`, so readiness,
blockers, gates and the priority order apply after the filter. `list` calls `pick_filter <adapter>
"$@"` from `lib/flow.sh`, which checks the filter and exports its fields comma-separated as
`FLOW_PICK_ASSIGNEE`, `FLOW_PICK_STATUS`, `FLOW_PICK_LABELS`, `FLOW_PICK_KINDS` and
`FLOW_PICK_QUERY`, and returns 1 when the filter's `trackers` leave the adapter out (the list is
then `[]`). A list field keeps an item that matches one of its values; the fields a filter sets
must all match. Without `--pick`, the list is what it was.

`pick-fields` in the adapter folder names, on one line, the fields the adapter maps. A filter with
a field the adapter does not map is refused, exit 2, naming the ones it does
(`pick.mine.query: the local adapter maps assignee, status, labels and kinds, not query`). So is a
name the config does not have (naming the ones it has), a `query` without exactly one tracker in
`trackers`, a `query` beside a neutral field, and a tracker the flow does not read.

| Adapter | assignee | status | labels | kinds | query |
|---|---|---|---|---|---|
| `github` | an issue assignee's login, any case; `me` is the `gh` user (`gh api user`) | the issue state, `open` or `closed` | the issue's labels, any case | the item's kind | GitHub search qualifiers, sent as `repo:<repo> is:issue is:open <query>` |
| `local` | the item file's `assignee`, any case; `me` is the git `user.email` or `user.name` | the item file's `status` (`open`, `closed`) | the item file's `labels`, any case | the item file's kind | not mapped |
| `jira` | JQL `assignee = "<value>"`; `me` is `currentUser()`, the `jira.email` user the token belongs to | JQL `status in (...)`, the status names | JQL `labels in (...)` | the item's kind, matched on the built items (a Story is a task) | a JQL condition, sent as `project = "<project>" AND (<query>) AND statusCategory != Done ORDER BY created DESC`, so it takes no `ORDER BY` |

GitHub and local match the filter on what they read; Jira puts it in the search, then counts each
listed issue's open children with a second search (`parent in (...)`), since the filter can leave
a child out. The fakes in tests read the filter as the trackers do: `_fake_gh.py` answers the
`search(query: ...)` call with the qualifiers `repo:`, `is:`, `label:` and `assignee:`, and
`_fake_jira.py` the JQL clauses in its `JQL_CLAUSES` (an issue's `fields.assignee` holds its
`emailAddress`, `accountId` and `displayName`); any other qualifier or clause fails, so a new one
cannot pass unseen. The contract suite assigns and labels items through `set_<name>` and reads
`me_<name>`, `open_status_<name>` and `query_<name>`; a new adapter adds those and its
`pick-fields`.

## Tracker scope

A tracker scope bounds every list and search of one tracker, for a tracker the team shares: the
board, `next`, the health and comments jobs and `answers` see only the items inside it, and the
flow runs and claims no named item outside it. The config sets it under the tracker's own key:

```yaml
github:
  scope:
    assignee: me              # the fields a pick filter takes, each as the pick table maps it
    labels: [team-api]
jira:
  scope:
    query: 'component = Backend'  # or the tracker's own search, alone
```

A scope takes `assignee`, `status`, `labels` and `kinds`, or `query` alone, the same fields a pick
filter takes and checked by the same code, and it names no `trackers`: it belongs to its tracker.
An empty field is unset, and a tracker with no scope reads as it did. `list` and `in-scope` call
`scope_filter <adapter>` from `lib/flow.sh`, which runs `scope_check` and exports the fields
comma-separated as `FLOW_SCOPE_ASSIGNEE`, `FLOW_SCOPE_STATUS`, `FLOW_SCOPE_LABELS`,
`FLOW_SCOPE_KINDS` and `FLOW_SCOPE_QUERY`, beside the `FLOW_PICK_*` of a pick. `scope_check`
refuses, exit 2, a scope that is no map of fields two spaces in (a value, a list, an inline map, or
fields no key of which reads), so a scope it cannot read never lists every item, `trackers` in a
scope, a field with lines under it no value of which reads (a map, a list at the field's own indent),
a field the adapter's `pick-fields` does not name and a `query` beside a neutral field, and
every message names the scope key
(`jira.scope.sprint: the jira adapter maps assignee, status, labels, kinds and query, not sprint`).
A refused scope stops every list of its tracker, so the board shows a tracker error and the health
job counts the tracker as failed; `init --check` names it as a gap.

A scope and a pick both apply: `list --pick <name>` keeps the items the scope and the filter both
match, and `list-ready` reads that list. A tracker limit (`jira.limit`, `github.limit`) caps the
scoped list, not the whole tracker.

| Adapter | assignee, status, labels | kinds | query | search |
|---|---|---|---|---|
| `github` | `assignee:<login>` (`me` is the `gh` user); `label:"a","b"` (any of them); `is:open` or `is:closed` when `status` names exactly one of them, no qualifier for both or neither | the item's kind, matched on the built item | GitHub search qualifiers, as written | with a scope set, every list is one `search(query: ...)`, `repo:<repo> is:issue [is:open] <scope> <pick query>`, so `github.limit` counts matches; a pick's neutral fields still match on what it reads |
| `local` | the item file's `assignee`, `status` and `labels`, as for a pick | the item file's kind | not mapped, refused | none: every item file, matched on its frontmatter |
| `jira` | JQL, as for a pick | the item's kind, matched on the built items | a JQL condition, as written | `project = "<project>" AND (<scope>) AND (<pick>) AND statusCategory != Done ORDER BY created DESC` (no `statusCategory` clause with `--all`), so a scope `query` composes with a pick `query` or with a pick's neutral fields |

`in-scope <id>` says whether one item is inside the scope, and with no scope set it exits 0 with
no tracker call. Local matches the item file. Jira sends one search,
`key = "<KEY>" AND project = "<project>" AND (<scope>)`, then matches the scope's kinds on the
built item. GitHub matches the kinds on the item `read` prints, then pages the scoped search's
issue numbers up to `github.limit`, so an issue past the limit reads as outside.

`read` stays unscoped. Blockers, parents, holders and bases resolve through it, so a blocker or an
epic outside the scope stays readable. An item that leaves the scope while it runs drops out of the
board, the health listing and the comments job, and keeps its claim, its worktree and its run. The
flow refuses to start one outside the scope:

- `next.sh <id>` on a named item outside the scope that holds no claim exits 2 with
  `<id> is outside <tracker>.scope in .flow/config.yaml; the flow does not run it`. An item claimed
  before it left the scope goes on. A picked item came from the scoped list, so it is not checked
  again.
- `steward.sh claim <id>` refuses a new claim of an item outside the scope the same way, exit 2,
  after the check for a claim it already holds. `adhoc:` claims have no tracker and are never
  scoped.
- When the tracker cannot say (GitHub's exit 3), both refuse with exit 2 and
  `<tracker> could not say whether <id> is inside <tracker>.scope; the flow does not run it`.

Open children differ. Jira ANDs the scope into both of its open-children searches (the
`parent in (...)` search of a list, which then always runs when a scope or a pick is set, and the
count in `read`), so a parent counts only its children inside the scope: with
`assignee = currentUser()`, a parent whose open children are all a teammate's reads as having
none, and can read ready. GitHub reads `subIssuesSummary`, which no search narrows, and local
scans every item file, so both count every open child.

`answers` reads the gates of the items inside the scope only (GitHub through its scoped list, Jira
with the scope in its search). A gate on an item that has left the scope waits until the owner
clears it with `scripts/gate.sh clear`.

GitHub caps a search at 1000 results, so a scope that matches more is cut there, below a higher
`github.limit`; narrow the scope rather than raise the limit.

The contract suite writes a scope through `scope_config_<name> <lines>`, which prints the scope
block at the end of the adapter's own config section; a new adapter adds it, its `in-scope.sh`
and the fields it maps in `pick-fields`.
