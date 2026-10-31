/**
 * The snapshot: one reconciled picture of a flow project. The daemon rebuilds it whenever a
 * source changes and the UI, the tray, a chat pane or an MCP tool all read this one shape.
 * Every timestamp is ISO 8601 in UTC. Every age is seconds at `takenAt`, so a reader can keep
 * counting on its own clock between snapshots.
 */
export const SNAPSHOT_SCHEMA_VERSION = 3;

/** A branch this many commits behind its base is stale, the health job's `behind_base` default. */
export const STALE_BEHIND_BASE_COMMITS = 20;
/** A claimed worktree with no run, no agent and no gate for this long is stale. */
export const STALE_IDLE_HOURS = 72;
/** A gate older than this is overdue, the health job's reminder threshold. */
export const GATE_OVERDUE_HOURS = 24;
/** How many events the snapshot carries, newest first. */
export const EVENTS_KEPT = 200;

export type WorktreeState = 'running' | 'needs-you' | 'stale' | 'claimed' | 'free' | 'outside';
export type WorktreeRole = 'main' | 'pool' | 'outside';
/**
 * Detail on a worktree card; flags never change the state on their own.
 * - `dirty`: the worktree has uncommitted files (changed or untracked).
 * - `behind`: its branch is at least one commit behind the base.
 * - `stale-branch`: a claimed branch is so far behind the base (`STALE_BEHIND_BASE_COMMITS`) that it needs the base merged in; the worktree is stale.
 * - `idle`: claimed for `STALE_IDLE_HOURS` or more with no run, no agent and no gate; the worktree is stale.
 * - `dead-run`: a run record names the worktree but no agent process is in it.
 * - `agent-without-claim`: an unattended agent works in a pool worktree nobody claimed.
 * - `session`: an interactive claude or codex (yours or an app's) has its working directory in the worktree.
 */
export type WorktreeFlag = 'dirty' | 'behind' | 'stale-branch' | 'idle' | 'dead-run' | 'agent-without-claim' | 'session';
export type ItemState = 'running' | 'needs-you' | 'stale' | 'claimed' | 'ready' | 'blocked' | 'backlog' | 'done';
export type JobState = 'running' | 'due' | 'scheduled' | 'paused' | 'not-installed' | 'not-loaded';
export type AgentHost = 'claude' | 'codex';
/** An agent is a run the flow started unattended; a session is a person's interactive host in that folder. */
export type AgentKind = 'agent' | 'session';
export type SourceName = 'files' | 'git' | 'processes' | 'jobs' | 'board' | 'pulls';
/** Every source, in the order the daemon reads them. The one list the routes and actions share. */
export const SOURCE_NAMES: SourceName[] = ['files', 'git', 'processes', 'jobs', 'board', 'pulls'];
/**
 * Why a row is on the needs-you list. `needs-field`: an item that is the next step of work already
 * under way but that the next job refuses because a field the tracker asks for (`ready_needs` in
 * .flow/config.yaml, such as priority or size) is empty: open, not an epic, no step, no open
 * blocker, and either its parent has started (a step, a worktree, a PR or a gate), a sibling
 * under the same parent has started or is done, or it blocks an item that has started. Other
 * items waiting on a field are backlog and get no row.
 */
export type AttentionKind = 'gate' | 'dead-run' | 'stale' | 'disagreement' | 'job-failed' | 'pr-failing' | 'pr-changes-requested' | 'pr-mergeable' | 'needs-field';
/**
 * Where an open pull request stands, the first that holds: a draft, merge conflicts, a failing
 * check, changes requested, a check still running, no approval yet, approved with checks or
 * threads not yet clean, and last ready to merge.
 */
export type PullState = 'draft' | 'conflicts' | 'checks-failing' | 'checks-pending' | 'changes-requested' | 'review-pending' | 'approved' | 'mergeable';

/** When a source was last read, how old that is, and whether the read worked. */
export type Freshness = {
  at: string | null;
  ageSeconds: number | null;
  ok: boolean;
  error: string | null;
};

/** How the project's flow plugin was found. */
export type PluginSource = 'installed' | 'FLOW_PLUGIN';

export type ProjectInfo = {
  id: string;
  name: string;
  root: string;
  flowHome: string;
  /** The branch work merges into, `base` in .flow/config.yaml (main by default). */
  base: string;
  /** `github.repo`, as `owner/name`. */
  repo: string | null;
  /** `https://github.com/<repo>`, or null without `github.repo`. */
  repoUrl: string | null;
  /** The tracker's page for the project's items: the GitHub issues page on the github adapter, null on local. */
  trackerUrl: string | null;
  /** The tracker adapter, `adapters.default`: `github` or `local`. */
  adapter: string;
  /** The flow plugin's version the project resolves, or null when no plugin was found. */
  pluginVersion: string | null;
  /** The folder of that plugin, or null when none was found. */
  pluginRoot: string | null;
  /**
   * How the plugin was found: `FLOW_PLUGIN` when the daemon was started with that variable (it
   * reaches every flow script), `installed` when .flow/plugin.sh found it in the plugin cache.
   */
  pluginSource: PluginSource | null;
  /** `jobs.host`: the CLI the scheduled jobs run unattended, `claude` or `codex`. */
  jobsHost: string;
  poolMax: number | null;
};

export type Claim = {
  item: string;
  branch: string;
  base: string;
  step: string;
  claimedAt: string;
  host: string;
};

/**
 * The session a claude or codex process writes: its id, the transcript file, and the argv that
 * opens it again (`claude --resume <id>`, `codex resume <id>`). A running `claude -p` cannot be
 * attached to; once it ends, the resume command picks the session up where it stopped.
 */
export type SessionRef = { host: AgentHost; id: string; transcript: string; resume: string[] };

/** One turn of a transcript with text in it, as `GET .../agents/<pid>/transcript` returns it. */
export type TranscriptTurn = { at: string | null; role: 'user' | 'assistant'; text: string };

/**
 * A claude or codex process with its working directory in a worktree. The command is trimmed to
 * `PROCESS_COMMAND_CHARS`. `session` is its transcript, or null when none was found (yet).
 */
export type ProcessInfo = { pid: number; host: AgentHost; command: string; elapsedSeconds: number; session: SessionRef | null };

/** How much of a process's command line the snapshot carries. */
export const PROCESS_COMMAND_CHARS = 200;

export type Worktree = {
  name: string;
  path: string;
  role: WorktreeRole;
  state: WorktreeState;
  flags: WorktreeFlag[];
  branch: string | null;
  head: string | null;
  aheadOfBase: number | null;
  behindBase: number | null;
  dirtyFiles: number | null;
  lastCommitAt: string | null;
  claim: Claim | null;
  claimAgeSeconds: number | null;
  item: string | null;
  /** The claimed item's tracker page, from the board; null with no item or before the board is read. */
  itemUrl: string | null;
  /** The claimed item's title, from the board; null with no item or before the board is read. */
  itemTitle: string | null;
  gate: string | null;
  /** Why the worktree is stale, in one sentence, or null when it is not. Both reasons join with "; ". */
  staleReason: string | null;
  /** Unattended agents (`claude -p`, `codex exec`) working in the worktree. */
  agents: ProcessInfo[];
  /**
   * Interactive sessions in the worktree: a claude or codex someone (you, or an app such as the
   * Claude desktop app) is typing into, whose working directory is in the worktree. Never an
   * unattended agent, and never a host's own server (`codex app-server`, `claude daemon`).
   */
  sessions: ProcessInfo[];
  /**
   * The refs the flow's sync note for the claimed item names (`<worktree>/.flow/reports/<item>/sync.md`,
   * one per line), which the item's next run merges first as the sync step; null with no claim or no note.
   * The health job writes it for a merge it cannot make cleanly, `sync.handoff` for a conflicted sync.
   */
  syncPending: string[] | null;
};

export type Item = {
  id: string;
  title: string;
  kind: string;
  size: string;
  priority: string;
  status: string;
  state: ItemState;
  step: string;
  gate: string;
  worktree: string | null;
  pr: string | null;
  url: string | null;
  parent: string | null;
  blockedBy: string[];
  openBlockers: string[];
  openChildren: number;
  needs: string[];
  rank: number;
  lastEvent: string | null;
};

export type GateQuestion = {
  number: number;
  text: string;
  recommended: string | null;
};

export type Gate = {
  item: string;
  gate: string;
  message: string;
  raisedAt: string;
  ageSeconds: number;
  overdue: boolean;
  host: string;
  worktree: string | null;
  questions: GateQuestion[];
  /**
   * The open pull request of the gate's item (the PR its `pr` field names, else the one on its
   * claimed branch), so a merge gate shows a review thread still open. Null when the item has no
   * open PR or pulls were not read.
   */
  pull: { number: number; url: string; state: PullState; unresolvedThreads: number } | null;
  /** The item's plan, `plan.md` else `epic.md` in its reports (the claimed worktree's, else the main one's), or null with none. */
  plan: GatePlan | null;
  /** The item's issue body as the board last read it, or null before a board read. */
  body: string | null;
};

export type GatePlan = { file: string; text: string };

export type Run = {
  item: string;
  step: string;
  profile: string;
  worktree: string;
  host: string;
  startedAt: string | null;
  alive: boolean;
};

export type Agent = {
  pid: number;
  host: AgentHost;
  kind: AgentKind;
  cwd: string;
  worktree: string | null;
  item: string | null;
  elapsedSeconds: number;
  command: string;
  /** Its transcript and how to resume it, or null when none was found. */
  session: SessionRef | null;
};

/** An agent or session that ended while the daemon watched, kept so its session can still be opened. */
export type EndedAgent = Agent & { endedAt: string };

/** How many ended agents and sessions the snapshot keeps, and for how long. */
export const ENDED_KEPT = 10;
export const ENDED_KEPT_HOURS = 24;

export type PullRequest = {
  number: number;
  title: string;
  url: string;
  branch: string;
  base: string;
  author: string;
  draft: boolean;
  state: PullState;
  checks: { passed: number; failed: number; pending: number };
  reviewDecision: string | null;
  unresolvedThreads: number;
  mergeable: string | null;
  item: string | null;
  worktree: string | null;
  createdAt: string;
  updatedAt: string;
  ageSeconds: number;
  idleSeconds: number;
};

export type JobRun = {
  at: string;
  seconds: number;
  exit: number | null;
  result: string;
  outcome: string;
};

export type Job = {
  name: string;
  state: JobState;
  schedule: string;
  args: string;
  installed: boolean;
  loaded: boolean;
  paused: boolean;
  running: string[];
  last: JobRun | null;
  next: string;
  runsThisWeek: number;
  failedThisWeek: number;
};

export type FlowEvent = {
  at: string;
  item: string | null;
  kind: string;
  message: string;
};

/** One button that settles a disagreement: an action to post, with its arguments and its label. */
export type DisagreementAction = { kind: ActionKind; args: Record<string, string>; label: string };

/**
 * Two places flow state lives say different things. Shown only once it held after every store
 * it names was read again, so a store that merely lags a cycle never flickers a row.
 */
export type Disagreement = {
  item: string | null;
  worktree: string | null;
  /** The two stores, such as `gate record` and `issue labels`. */
  sources: string[];
  message: string;
  /** One plain sentence: what each store says and which one is usually right. */
  explain: string;
  /** What settles it, or null when a person has to look. */
  action: DisagreementAction | null;
};

export type AttentionRow = {
  kind: AttentionKind;
  id: string;
  title: string;
  detail: string;
  worktree: string | null;
  sinceAt: string | null;
  ageSeconds: number | null;
};

export type Counts = {
  needsYou: number;
  running: number;
  stale: number;
  claimed: number;
  free: number;
  agents: number;
  jobsRunning: number;
  itemsReady: number;
  itemsBlocked: number;
  itemsBacklog: number;
  itemsDone: number;
  disagreements: number;
  pullsMergeable: number;
  pullsFailing: number;
  pullsChangesRequested: number;
  /** The `needs-field` attention rows: items next in line for work under way that lack a field. Same as `readiness.nextInLineMissingField`. */
  needsField: number;
};

/**
 * Why open work does or does not run, over open items that are not epics. The first four are
 * buckets, each item in one at most: `ready` the next job can take it; `waitingOnField` nothing
 * blocks it but a field it needs is empty (the whole backlog of them); `blocked` an open item
 * blocks it; `gated` it waits on you at a gate. Items already running, claimed or stale are in
 * none. `nextInLineMissingField` is the part of `waitingOnField` that is the next step of work
 * already under way (the `needs-field` rows), so a reader can say "164 backlog items lack a
 * field; 4 of them are the next step of work in progress".
 */
export type Readiness = {
  ready: number;
  waitingOnField: number;
  blocked: number;
  gated: number;
  nextInLineMissingField: number;
};

export type Snapshot = {
  schema: typeof SNAPSHOT_SCHEMA_VERSION;
  takenAt: string;
  project: ProjectInfo;
  sources: Record<SourceName, Freshness>;
  counts: Counts;
  readiness: Readiness;
  attention: AttentionRow[];
  worktrees: Worktree[];
  items: Item[];
  gates: Gate[];
  runs: Run[];
  agents: Agent[];
  /** Agents and sessions with a transcript that ended in the last day while the daemon watched, newest first. */
  ended: EndedAgent[];
  jobs: Job[];
  pulls: PullRequest[];
  events: FlowEvent[];
  disagreements: Disagreement[];
};

/*
 * Actions: every write the console makes goes through a flow script that the daemon runs. The
 * record below is what `POST /api/projects/<id>/actions` returns and what the `action` event on
 * the stream carries. `outputTail` is the last few kilobytes; `GET .../actions/<id>` has it all.
 */
export type ActionKind =
  | 'gate.clear'
  | 'run.start'
  | 'job.run'
  | 'job.stop'
  | 'job.pause'
  | 'job.resume'
  | 'worktree.claim'
  | 'worktree.release'
  | 'worktree.sync'
  | 'sync.handoff'
  | 'item.step-sync'
  | 'steward.health'
  | 'jobs.install'
  | 'job.uninstall'
  | 'pr.merge'
  | 'terminal.open'
  | 'refresh';
export type ActionState = 'running' | 'done' | 'failed' | 'rejected';
/**
 * What a successful action did. `started`: the work was handed on and goes on after the record
 * (`job.run`, `steward.health` and `run.start` without an item hand a job to launchd; a detached
 * `run.start` is `started` from the moment its process runs). `finished`: the work is over
 * (every other kind on a clean exit, and a detached run once it ends cleanly). Null while an
 * attached action runs, and on a failed or rejected one.
 */
export type ActionOutcome = 'started' | 'finished';

/** How a `worktree.sync` conflicted: the refs still to merge (the conflicting one first, in the order sync.sh tries them) and the files git reported. */
export type SyncConflict = { refs: string[]; files: string[] };

export type ActionRecord = {
  id: string;
  kind: ActionKind;
  args: Record<string, string>;
  state: ActionState;
  /** The program and its arguments as run, for the audit trail and the UI. */
  command: string[];
  /** What the action holds while it runs: an item, a worktree, a job, a PR, the pool. Two actions never share one. */
  locks: string[];
  requestedAt: string;
  startedAt: string | null;
  endedAt: string | null;
  exitCode: number | null;
  timedOut: boolean;
  outcome: ActionOutcome | null;
  outputTail: string;
  outputBytes: number;
  output?: string;
  /** What a finished action wants said beside its state, such as the jobs `jobs.sh install` left as they were; null for most. */
  note: string | null;
  /** Set when a `worktree.sync` ended in a merge conflict, which it aborted; null for every other ending and kind. */
  conflict: SyncConflict | null;
};

/*
 * Settings: what `GET /api/settings` returns and the Settings screen shows. The file behind them
 * is ~/.config/brain-console/config.json; `daemon/src/settings.ts` reads, checks and writes it.
 */
export type TerminalName = 'iterm' | 'terminal' | 'ghostty';
/** A terminal app the console knows by name, or the owner's own command with `{path}` (and `{cmd}`) in it. */
export type TerminalSetting = TerminalName | { command: string[] };
/** Where a setting came from: a start flag, the environment, the config file, or the daemon's default. */
export type SettingOrigin = 'flag' | 'environment' | 'file' | 'default';

/** The settings as `GET /api/settings` reports them: each value with where it came from. */
export type SettingsView = {
  configFile: string;
  /** The old projects.json the projects were read from because config.json is absent, else null. */
  readFromLegacyFile: string | null;
  stateDir: string;
  /** True when launchd started the daemon (`install`), so it comes back on login and after a crash. */
  launchd: boolean;
  projects: { roots: string[]; from: SettingOrigin; editable: boolean; note: string | null };
  terminal: { value: TerminalSetting | null; from: SettingOrigin; installed: TerminalName[] };
  port: { value: number; from: SettingOrigin; saved: number | null; note: string };
};

