import path from 'node:path';
import type { BoardFacts, BoardItem } from './collectors/board.ts';
import type { ClaimRecord, FlowHomeFacts, GateRecord, RunRecord } from './collectors/flowHome.ts';
import { poolPaths } from './collectors/flowHome.ts';
import type { GitFacts, GitWorktree } from './collectors/git.ts';
import type { JobFacts, JobStatusRow } from './collectors/jobs.ts';
import type { AgentProcess, ProcessFacts } from './collectors/processes.ts';
import type { PullFact, PullFacts } from './collectors/pulls.ts';
import { parseGateQuestions } from './gateMessage.ts';
import {
  GATE_OVERDUE_HOURS, SNAPSHOT_SCHEMA_VERSION, STALE_BEHIND_BASE_COMMITS, STALE_IDLE_HOURS,
} from './snapshot.ts';
import type {
  Agent, AttentionRow, Claim, Counts, Disagreement, Freshness, Gate, Item, ItemState, Job, JobState, PullRequest, PullState, Run,
  Snapshot, SourceName, Worktree, WorktreeFlag, WorktreeRole, WorktreeState,
} from './snapshot.ts';

export type ReconcileInput = {
  now: Date;
  project: { id: string; name: string; root: string };
  flow: FlowHomeFacts;
  git: GitFacts | null;
  processes: ProcessFacts | null;
  jobs: JobFacts | null;
  board: BoardFacts | null;
  pulls: PullFacts | null;
  sources: Record<SourceName, Freshness>;
};

const MILLISECONDS_PER_SECOND = 1000;
const SECONDS_PER_HOUR = 3600;
const UNRANKED = 999;
/** The merge gate: the one gate that asks a person to merge a ready pull request. */
const MERGE_GATE = 'merge';
const PULL_PATH = /^(.*\/pull\/\d+)/;
/** GitHub's merge states that let a merge through; UNSTABLE means only checks no rule requires are red. */
const MERGE_READY_STATES = ['CLEAN', 'HAS_HOOKS', 'UNSTABLE'];
const PULL_NUMBER = /^#?(\d+)$/;
const STATE_ORDER: Record<ItemState, number> = {
  'needs-you': 0, running: 1, stale: 2, claimed: 3, ready: 4, blocked: 5, backlog: 6, done: 7,
};

export function ageSeconds(from: string | null, now: Date): number | null {
  if (from === null || from.length === 0) return null;
  const then = Date.parse(from);
  if (Number.isNaN(then)) return null;
  return Math.max(0, Math.floor((now.getTime() - then) / MILLISECONDS_PER_SECOND));
}

type WorktreeContext = {
  path: string;
  name: string;
  role: WorktreeRole;
  git: GitWorktree | null;
  claim: ClaimRecord | null;
  gate: GateRecord | null;
  run: RunRecord | null;
  agents: AgentProcess[];
  sessions: AgentProcess[];
};

function under(cwd: string, worktreePath: string): boolean {
  return cwd === worktreePath || cwd.startsWith(worktreePath + path.sep);
}

function worktreeContexts(input: ReconcileInput): WorktreeContext[] {
  const root = path.resolve(input.project.root);
  const pool = poolPaths(root, input.flow.config);
  const gitByPath = new Map((input.git?.worktrees ?? []).map((entry) => [path.resolve(entry.path), entry]));
  const known = [root, ...pool, ...[...gitByPath.keys()].filter((entry) => entry !== root && !pool.includes(entry)).sort()];
  const processes = input.processes?.agents ?? [];
  return known.map((worktreePath) => {
    const claim = input.flow.claims.find((entry) => path.resolve(entry.worktreePath) === worktreePath) ?? null;
    const name = path.basename(worktreePath);
    return {
      path: worktreePath,
      name,
      role: worktreePath === root ? 'main' : pool.includes(worktreePath) ? 'pool' : 'outside',
      git: gitByPath.get(worktreePath) ?? null,
      claim,
      gate: claim === null ? null : input.flow.gates.find((gate) => gate.item === claim.item) ?? null,
      run: input.flow.runs.find((run) => path.resolve(run.worktree) === worktreePath || (claim !== null && run.item === claim.item)) ?? null,
      agents: processes.filter((process) => process.kind === 'agent' && under(process.cwd, worktreePath)),
      sessions: processes.filter((process) => process.kind === 'session' && under(process.cwd, worktreePath)),
    };
  });
}

function worktreeState(context: WorktreeContext, flags: WorktreeFlag[]): WorktreeState {
  if (context.role !== 'pool') return 'outside';
  if (context.agents.length > 0 || (context.run !== null && !flags.includes('dead-run'))) return 'running';
  if (context.gate !== null) return 'needs-you';
  if (flags.includes('stale-branch') || flags.includes('idle')) return 'stale';
  if (context.claim !== null) return 'claimed';
  return 'free';
}

function worktreeFlags(context: WorktreeContext, now: Date): WorktreeFlag[] {
  const flags: WorktreeFlag[] = [];
  const behind = context.git?.behindBase ?? 0;
  const dirty = context.git?.dirtyFiles ?? 0;
  if (dirty > 0) flags.push('dirty');
  if (behind > 0) flags.push('behind');
  if (context.claim !== null && behind >= STALE_BEHIND_BASE_COMMITS) flags.push('stale-branch');
  const claimAge = context.claim === null ? null : ageSeconds(context.claim.claimedAt, now);
  const quiet = context.agents.length === 0 && context.run === null && context.gate === null;
  if (quiet && claimAge !== null && claimAge >= STALE_IDLE_HOURS * SECONDS_PER_HOUR) flags.push('idle');
  if (context.run !== null && context.agents.length === 0) flags.push('dead-run');
  if (context.role === 'pool' && context.claim === null && context.agents.length > 0) flags.push('agent-without-claim');
  if (context.sessions.length > 0) flags.push('session');
  return flags;
}

function toClaim(record: ClaimRecord): Claim {
  return { item: record.item, branch: record.branch, base: record.base, step: record.step, claimedAt: record.claimedAt, host: record.host };
}

function buildWorktrees(contexts: WorktreeContext[], now: Date): Worktree[] {
  return contexts.map((context) => {
    const flags = worktreeFlags(context, now);
    return {
      name: context.name,
      path: context.path,
      role: context.role,
      state: worktreeState(context, flags),
      flags,
      branch: context.git?.branch ?? context.claim?.branch ?? null,
      head: context.git?.head ?? null,
      aheadOfBase: context.git?.aheadOfBase ?? null,
      behindBase: context.git?.behindBase ?? null,
      dirtyFiles: context.git?.dirtyFiles ?? null,
      lastCommitAt: context.git?.lastCommitAt ?? null,
      claim: context.claim === null ? null : toClaim(context.claim),
      claimAgeSeconds: context.claim === null ? null : ageSeconds(context.claim.claimedAt, now),
      item: context.claim?.item ?? null,
      gate: context.gate?.gate ?? null,
      agentPids: context.agents.map((agent) => agent.pid),
      sessionPids: context.sessions.map((session) => session.pid),
    };
  });
}

function itemState(boardItem: BoardItem | null, worktree: Worktree | null, gate: GateRecord | null): ItemState {
  if (worktree !== null && worktree.state !== 'free' && worktree.state !== 'outside') return worktree.state;
  if (gate !== null) return 'needs-you';
  if (boardItem === null) return 'claimed';
  if (boardItem.status !== 'open') return 'done';
  if (boardItem.open_blockers.length > 0) return 'blocked';
  if (boardItem.needs.length > 0) return 'backlog';
  return 'ready';
}

function buildItems(input: ReconcileInput, worktrees: Worktree[]): Item[] {
  const byItem = new Map(worktrees.filter((entry) => entry.item !== null).map((entry) => [entry.item as string, entry]));
  const boardItems = input.board?.items ?? [];
  const engagedIds = new Set([...byItem.keys(), ...input.flow.gates.map((gate) => gate.item)]);
  const seen = new Set<string>();
  const items: Item[] = [];
  for (const boardItem of boardItems) {
    seen.add(boardItem.id);
    const worktree = byItem.get(boardItem.id) ?? null;
    const gate = input.flow.gates.find((entry) => entry.item === boardItem.id) ?? null;
    items.push({
      id: boardItem.id, title: boardItem.title, kind: boardItem.kind, size: boardItem.size, priority: boardItem.priority,
      status: boardItem.status, state: itemState(boardItem, worktree, gate), step: worktree?.claim?.step ?? boardItem.state.step,
      gate: gate?.gate ?? boardItem.state.gate, worktree: worktree?.name ?? (boardItem.state.worktree || null),
      pr: boardItem.state.pr || null, url: boardItem.url || null, parent: boardItem.parent || null,
      blockedBy: boardItem.blocked_by, openBlockers: boardItem.open_blockers, openChildren: boardItem.open_children,
      needs: boardItem.needs, rank: boardItem.rank, lastEvent: boardItem.state.last_event || null,
    });
  }
  for (const id of [...engagedIds].filter((entry) => !seen.has(entry)).sort()) {
    const worktree = byItem.get(id) ?? null;
    const gate = input.flow.gates.find((entry) => entry.item === id) ?? null;
    items.push({
      id, title: '', kind: '', size: '', priority: '', status: 'open', state: itemState(null, worktree, gate),
      step: worktree?.claim?.step ?? '', gate: gate?.gate ?? 'none', worktree: worktree?.name ?? null, pr: null, url: null,
      parent: null, blockedBy: [], openBlockers: [], openChildren: 0, needs: [], rank: UNRANKED, lastEvent: null,
    });
  }
  return items.sort((left, right) => STATE_ORDER[left.state] - STATE_ORDER[right.state] || left.rank - right.rank || left.id.localeCompare(right.id));
}

function buildGates(input: ReconcileInput, contexts: WorktreeContext[]): Gate[] {
  return input.flow.gates
    .map((gate) => ({
      item: gate.item, gate: gate.gate, message: gate.message, raisedAt: gate.time,
      ageSeconds: ageSeconds(gate.time, input.now) ?? 0,
      overdue: (ageSeconds(gate.time, input.now) ?? 0) >= GATE_OVERDUE_HOURS * SECONDS_PER_HOUR,
      host: gate.host,
      worktree: contexts.find((context) => context.claim?.item === gate.item)?.name ?? null,
      questions: parseGateQuestions(gate.message),
    }))
    .sort((left, right) => right.ageSeconds - left.ageSeconds);
}

function buildRuns(input: ReconcileInput, contexts: WorktreeContext[]): Run[] {
  return input.flow.runs.map((run) => {
    const context = contexts.find((entry) => entry.run === run) ?? null;
    return {
      item: run.item, step: run.step, profile: run.profile, worktree: path.basename(run.worktree), host: run.host,
      startedAt: run.startedAt, alive: context !== null && context.agents.length > 0,
    };
  });
}

function buildAgents(input: ReconcileInput, contexts: WorktreeContext[]): Agent[] {
  return (input.processes?.agents ?? []).flatMap((agent) => {
    const context = contexts.find((entry) => under(agent.cwd, entry.path)) ?? null;
    if (context === null) return [];
    return [{
      pid: agent.pid, host: agent.host, kind: agent.kind, cwd: agent.cwd, worktree: context.name, item: context.claim?.item ?? null,
      elapsedSeconds: agent.elapsedSeconds, command: agent.command,
    }];
  });
}

function jobState(row: JobStatusRow): JobState {
  if (row.paused) return 'paused';
  if (!row.installed) return 'not-installed';
  if (!row.loaded) return 'not-loaded';
  if (row.running.length > 0) return 'running';
  if (row.next === 'due') return 'due';
  return 'scheduled';
}

function buildJobs(input: ReconcileInput): Job[] {
  return (input.jobs?.jobs ?? []).map((row) => ({
    name: row.job, state: jobState(row), schedule: row.schedule, args: row.args, installed: row.installed, loaded: row.loaded,
    paused: row.paused, running: row.running.map((entry) => entry.job),
    last: row.last === null ? null : {
      at: row.last.at, seconds: row.last.seconds, exit: typeof row.last.exit === 'number' ? row.last.exit : null,
      result: row.last.result, outcome: row.last.outcome,
    },
    next: row.next,
    runsThisWeek: Object.values(row.week).reduce((sum, count) => sum + count, 0),
    failedThisWeek: row.week['failed'] ?? 0,
  }));
}

/** With no review decision the repository requires no review, so approval is not needed. */
function approvalSatisfied(pull: PullFact): boolean {
  return pull.reviewDecision === null || pull.reviewDecision === 'APPROVED';
}

function changesRequested(pull: PullFact): boolean {
  return pull.reviewDecision === 'CHANGES_REQUESTED' || (pull.reviewDecision === null && pull.changesRequested > 0);
}

function mergesCleanly(pull: PullFact): boolean {
  return pull.unresolvedThreads === 0 && pull.mergeable === 'MERGEABLE' && MERGE_READY_STATES.includes(pull.mergeState ?? '');
}

export function pullState(pull: PullFact): PullState {
  if (pull.draft) return 'draft';
  if (pull.mergeable === 'CONFLICTING' || pull.mergeState === 'DIRTY') return 'conflicts';
  if (pull.checks.failed > 0) return 'checks-failing';
  if (changesRequested(pull)) return 'changes-requested';
  if (pull.checks.pending > 0) return 'checks-pending';
  if (!approvalSatisfied(pull)) return 'review-pending';
  if (!mergesCleanly(pull)) return 'approved';
  return 'mergeable';
}

function pullPath(value: string): string | null {
  try {
    const url = new URL(value);
    if (url.protocol !== 'https:' && url.protocol !== 'http:') return null;
    const found = PULL_PATH.exec(url.pathname.toLowerCase());
    return found === null ? null : `${url.host.toLowerCase()}${found[1]}`;
  } catch { return null; }
}

/** An item's `pr` field names its pull by number (`560`, `#560`) or by URL. */
function namesPull(field: string | null, pull: PullFact): boolean {
  if (field === null) return false;
  const value = field.trim();
  const named = pullPath(value);
  if (named !== null) return named === pullPath(pull.url);
  const pullNumber = PULL_NUMBER.exec(value);
  return pullNumber !== null && Number(pullNumber[1]) === pull.number;
}

type PullLink = { item: string | null; worktree: string | null };

function linkPull(pull: PullFact, items: Item[], contexts: WorktreeContext[]): PullLink {
  const named = items.find((item) => namesPull(item.pr, pull));
  if (named !== undefined) return { item: named.id, worktree: named.worktree };
  if (pull.crossRepository) return { item: null, worktree: null };
  const claimed = contexts.find((context) => context.claim !== null && context.claim.branch === pull.branch);
  if (claimed !== undefined) return { item: claimed.claim?.item ?? null, worktree: claimed.name };
  return { item: null, worktree: null };
}

function buildPulls(input: ReconcileInput, items: Item[], contexts: WorktreeContext[]): PullRequest[] {
  return (input.pulls?.pulls ?? []).map((pull) => ({
    number: pull.number, title: pull.title, url: pull.url, branch: pull.branch, base: pull.base, author: pull.author,
    draft: pull.draft, state: pullState(pull), checks: pull.checks, reviewDecision: pull.reviewDecision,
    unresolvedThreads: pull.unresolvedThreads, mergeable: pull.mergeable, ...linkPull(pull, items, contexts),
    createdAt: pull.createdAt, updatedAt: pull.updatedAt,
    ageSeconds: ageSeconds(pull.createdAt, input.now) ?? 0, idleSeconds: ageSeconds(pull.updatedAt, input.now) ?? 0,
  }));
}

/**
 * What says a done item waits on a merge. With pull requests read, its PR must be ready to merge;
 * without them (not read yet, or not on GitHub), the issue state naming a PR is all there is.
 */
function mergeEvidence(item: Item, pulls: PullRequest[] | null): string | null {
  if (pulls === null) return item.pr === null ? null : `names the open PR ${item.pr}`;
  const ready = pulls.find((pull) => pull.item === item.id && pull.state === 'mergeable');
  return ready === undefined ? null : `#${ready.number} is ready to merge`;
}

function buildDisagreements(input: ReconcileInput, contexts: WorktreeContext[], items: Item[], pulls: PullRequest[]): Disagreement[] {
  const out: Disagreement[] = [];
  const board = new Map((input.board?.items ?? []).map((item) => [item.id, item]));
  for (const context of contexts) {
    if (context.run !== null && context.agents.length === 0) {
      out.push({ item: context.run.item, worktree: context.name, sources: ['run record', 'process list'], message: `${context.run.item} has a run record in ${context.name} but no agent process. The health job clears it after the grace.` });
    }
    if (context.role === 'pool' && context.claim === null && context.agents.length > 0) {
      out.push({ item: null, worktree: context.name, sources: ['process list', 'claim'], message: `An agent runs in ${context.name} but the worktree has no claim.` });
    }
    const claimed = context.claim === null ? null : board.get(context.claim.item) ?? null;
    if (context.claim !== null && claimed !== null && claimed.state.step !== '' && claimed.state.step !== context.claim.step) {
      out.push({ item: context.claim.item, worktree: context.name, sources: ['claim', 'issue state'], message: `${context.claim.item}: the claim says step ${context.claim.step}, the issue says ${claimed.state.step}.` });
    }
    if (context.claim !== null && claimed !== null && claimed.state.worktree !== '' && claimed.state.worktree !== context.name) {
      out.push({ item: context.claim.item, worktree: context.name, sources: ['claim', 'issue state'], message: `${context.claim.item} is claimed in ${context.name}, the issue names ${claimed.state.worktree}.` });
    }
  }
  for (const gate of input.flow.gates) {
    const item = board.get(gate.item);
    if (item !== undefined && item.state.gate !== gate.gate) {
      out.push({ item: gate.item, worktree: null, sources: ['gate record', 'issue labels'], message: `${gate.item}: the gate record says ${gate.gate}, the issue labels say ${item.state.gate}.` });
    }
  }
  for (const item of items.filter((entry) => entry.status === 'open' && entry.step === 'done' && entry.gate !== MERGE_GATE)) {
    const evidence = mergeEvidence(item, input.pulls === null ? null : pulls);
    if (evidence !== null) out.push({ item: item.id, worktree: item.worktree, sources: ['issue state', 'pull request'], message: `${item.id} is at step done and ${evidence}, but no merge gate asks you to merge it.` });
  }
  return out;
}

const PULL_ATTENTION: Partial<Record<PullState, { kind: AttentionRow['kind']; title: string }>> = {
  'checks-failing': { kind: 'pr-failing', title: 'checks failing' },
  'changes-requested': { kind: 'pr-changes-requested', title: 'changes requested' },
  mergeable: { kind: 'pr-mergeable', title: 'ready to merge' },
};

function pullAttention(pulls: PullRequest[]): AttentionRow[] {
  return pulls.flatMap((pull) => {
    const row = PULL_ATTENTION[pull.state];
    if (row === undefined) return [];
    return [{ kind: row.kind, id: pull.item ?? `#${pull.number}`, title: `#${pull.number} ${row.title}`, detail: pull.title, worktree: pull.worktree, sinceAt: pull.updatedAt, ageSeconds: pull.idleSeconds }];
  });
}

type AttentionSources = { gates: Gate[]; worktrees: Worktree[]; runs: Run[]; jobs: Job[]; pulls: PullRequest[]; disagreements: Disagreement[] };

function buildAttention({ gates, worktrees, runs, jobs, pulls, disagreements }: AttentionSources, now: Date): AttentionRow[] {
  const rows: AttentionRow[] = [];
  for (const gate of gates) {
    rows.push({ kind: 'gate', id: gate.item, title: `${gate.gate} gate on ${gate.item}`, detail: gate.questions[0]?.text ?? gate.message, worktree: gate.worktree, sinceAt: gate.raisedAt, ageSeconds: gate.ageSeconds });
  }
  for (const run of runs.filter((entry) => !entry.alive)) {
    rows.push({ kind: 'dead-run', id: run.item, title: `${run.item} has a run record but no process`, detail: `step ${run.step} in ${run.worktree}`, worktree: run.worktree, sinceAt: run.startedAt, ageSeconds: ageSeconds(run.startedAt, now) });
  }
  for (const worktree of worktrees.filter((entry) => entry.flags.includes('stale-branch') || entry.flags.includes('idle'))) {
    const reason = worktree.flags.includes('stale-branch') ? `${worktree.behindBase} commits behind ${worktree.claim?.base ?? 'base'}` : 'no run, agent or gate for days';
    rows.push({ kind: 'stale', id: worktree.item ?? worktree.name, title: `${worktree.name} is stale`, detail: reason, worktree: worktree.name, sinceAt: worktree.claim?.claimedAt ?? null, ageSeconds: worktree.claimAgeSeconds });
  }
  for (const job of jobs.filter((entry) => entry.last !== null && entry.last.exit !== null && entry.last.exit !== 0)) {
    rows.push({ kind: 'job-failed', id: job.name, title: `${job.name} job failed`, detail: job.last?.result ?? '', worktree: null, sinceAt: job.last?.at ?? null, ageSeconds: ageSeconds(job.last?.at ?? null, now) });
  }
  rows.push(...pullAttention(pulls));
  for (const disagreement of disagreements) {
    rows.push({ kind: 'disagreement', id: disagreement.item ?? disagreement.worktree ?? 'project', title: disagreement.sources.join(' vs '), detail: disagreement.message, worktree: disagreement.worktree, sinceAt: null, ageSeconds: null });
  }
  return rows.sort((left, right) => (right.ageSeconds ?? -1) - (left.ageSeconds ?? -1));
}

type CountSources = { worktrees: Worktree[]; items: Item[]; agents: Agent[]; jobs: Job[]; gates: Gate[]; pulls: PullRequest[]; disagreements: Disagreement[] };

function buildCounts({ worktrees, items, agents, jobs, gates, pulls, disagreements }: CountSources): Counts {
  const pool = worktrees.filter((entry) => entry.role === 'pool');
  const count = (state: WorktreeState): number => pool.filter((entry) => entry.state === state).length;
  const itemCount = (state: ItemState): number => items.filter((entry) => entry.state === state).length;
  const pullCount = (state: PullState): number => pulls.filter((entry) => entry.state === state).length;
  return {
    needsYou: gates.length, running: count('running'), stale: count('stale'), claimed: count('claimed'), free: count('free'),
    agents: agents.filter((entry) => entry.kind === 'agent').length, jobsRunning: jobs.filter((entry) => entry.state === 'running').length,
    itemsReady: itemCount('ready'), itemsBlocked: itemCount('blocked'), itemsBacklog: itemCount('backlog'), itemsDone: itemCount('done'),
    disagreements: disagreements.length,
    pullsMergeable: pullCount('mergeable'), pullsFailing: pullCount('checks-failing'), pullsChangesRequested: pullCount('changes-requested'),
  };
}

export function reconcile(input: ReconcileInput): Snapshot {
  const contexts = worktreeContexts(input);
  const worktrees = buildWorktrees(contexts, input.now);
  const items = buildItems(input, worktrees);
  const gates = buildGates(input, contexts);
  const runs = buildRuns(input, contexts);
  const agents = buildAgents(input, contexts);
  const jobs = buildJobs(input);
  const pulls = buildPulls(input, items, contexts);
  const disagreements = buildDisagreements(input, contexts, items, pulls);
  return {
    schema: SNAPSHOT_SCHEMA_VERSION,
    takenAt: input.now.toISOString(),
    project: {
      id: input.project.id, name: input.project.name, root: input.project.root, flowHome: input.flow.flowHome,
      base: input.flow.config.base, repo: input.flow.config.repo, adapter: input.flow.config.adapter,
      pluginVersion: input.flow.pluginVersion, poolMax: input.flow.config.poolMax,
    },
    sources: input.sources,
    counts: buildCounts({ worktrees, items, agents, jobs, gates, pulls, disagreements }),
    attention: buildAttention({ gates, worktrees, runs, jobs, pulls, disagreements }, input.now),
    worktrees, items, gates, runs, agents, jobs, pulls,
    events: input.flow.events,
    disagreements,
  };
}
