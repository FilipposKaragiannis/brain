/**
 * The snapshot: one reconciled picture of a flow project. The daemon rebuilds it whenever a
 * source changes and the UI, the tray, a chat pane or an MCP tool all read this one shape.
 * Every timestamp is ISO 8601 in UTC. Every age is seconds at `takenAt`, so a reader can keep
 * counting on its own clock between snapshots.
 */
export const SNAPSHOT_SCHEMA_VERSION = 1;

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
export type WorktreeFlag = 'dirty' | 'behind' | 'stale-branch' | 'idle' | 'dead-run' | 'agent-without-claim' | 'session';
export type ItemState = 'running' | 'needs-you' | 'stale' | 'claimed' | 'ready' | 'blocked' | 'backlog' | 'done';
export type JobState = 'running' | 'due' | 'scheduled' | 'paused' | 'not-installed' | 'not-loaded';
export type AgentHost = 'claude' | 'codex';
/** An agent is a run the flow started unattended; a session is a person's interactive host in that folder. */
export type AgentKind = 'agent' | 'session';
export type SourceName = 'files' | 'git' | 'processes' | 'jobs' | 'board' | 'pulls';
/** Every source, in the order the daemon reads them. The one list the routes and actions share. */
export const SOURCE_NAMES: SourceName[] = ['files', 'git', 'processes', 'jobs', 'board', 'pulls'];
export type AttentionKind = 'gate' | 'dead-run' | 'stale' | 'disagreement' | 'job-failed' | 'pr-failing' | 'pr-changes-requested' | 'pr-mergeable';
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

export type ProjectInfo = {
  id: string;
  name: string;
  root: string;
  flowHome: string;
  base: string;
  repo: string | null;
  adapter: string;
  pluginVersion: string | null;
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
  gate: string | null;
  agentPids: number[];
  sessionPids: number[];
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
};

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
};

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

export type Disagreement = {
  item: string | null;
  worktree: string | null;
  sources: string[];
  message: string;
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
};

export type Snapshot = {
  schema: typeof SNAPSHOT_SCHEMA_VERSION;
  takenAt: string;
  project: ProjectInfo;
  sources: Record<SourceName, Freshness>;
  counts: Counts;
  attention: AttentionRow[];
  worktrees: Worktree[];
  items: Item[];
  gates: Gate[];
  runs: Run[];
  agents: Agent[];
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
  | 'steward.health'
  | 'pr.merge'
  | 'refresh';
export type ActionState = 'running' | 'done' | 'failed' | 'rejected';

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
  outputTail: string;
  outputBytes: number;
  output?: string;
};
