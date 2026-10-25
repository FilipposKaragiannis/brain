import { watch } from 'node:fs';
import type { FSWatcher } from 'node:fs';
import path from 'node:path';
import type { BoardFacts } from './collectors/board.ts';
import { readBoard } from './collectors/board.ts';
import type { CommandRunner } from './collectors/exec.ts';
import type { FlowHomeFacts, GateQuestionCache } from './collectors/flowHome.ts';
import { flowHomeOf, poolPaths, readFlowHome } from './collectors/flowHome.ts';
import type { GitFacts } from './collectors/git.ts';
import { readGit } from './collectors/git.ts';
import type { JobFacts } from './collectors/jobs.ts';
import { readJobs } from './collectors/jobs.ts';
import type { EndedProcess, ProcessFacts } from './collectors/processes.ts';
import { readProcesses } from './collectors/processes.ts';
import type { SessionLocator } from './collectors/sessions.ts';
import { noSessions } from './collectors/sessions.ts';
import type { ActionContext } from './actionPlan.ts';
import type { PullFacts } from './collectors/pulls.ts';
import { readPulls } from './collectors/pulls.ts';
import type { Logger } from './log.ts';
import { ageSeconds, reconcile } from './reconcile.ts';
import { DisagreementSettler, disagreementKey } from './settle.ts';
import type { ReadMarks } from './settle.ts';
import type { Freshness, Snapshot, SourceName } from './snapshot.ts';
import { ENDED_KEPT } from './snapshot.ts';

/** How often each source is re-read, in milliseconds. File changes also trigger `files` and `git` at once. */
export type Cadence = { filesMs: number; gitMs: number; processesMs: number; jobsMs: number; boardMs: number; pullsMs: number };

export const DEFAULT_CADENCE: Cadence = { filesMs: 30000, gitMs: 30000, processesMs: 10000, jobsMs: 60000, boardMs: 120000, pullsMs: 60000 };

const WATCH_DEBOUNCE_MS = 500;
/** Pull requests are read from GitHub; a project on another tracker has none to show. */
const PULLS_ADAPTER = 'github';
/** Folders under the flow home whose churn never changes the snapshot. */
const UNWATCHED_FOLDERS = ['log', 'tmp', 'reports', 'reviews', 'health'];

export type ProjectDefinition = { id: string; name: string; root: string };

type Reading<T> = { facts: T | null; freshness: Freshness };

type Facts = {
  files: Reading<FlowHomeFacts>;
  git: Reading<GitFacts>;
  processes: Reading<ProcessFacts>;
  jobs: Reading<JobFacts>;
  board: Reading<BoardFacts>;
  pulls: Reading<PullFacts>;
};

export type ProjectMonitorDependencies = {
  project: ProjectDefinition;
  runner: CommandRunner;
  clock: () => Date;
  log: Logger;
  cadence: Cadence;
  /** Finds each process's transcript; left out, no process has a session. */
  sessions?: Pick<SessionLocator, 'assign'>;
};

const unread = (): Freshness => ({ at: null, ageSeconds: null, ok: false, error: 'not read yet' });

/**
 * Owns one project: reads every source on its cadence, re-reads the fast ones when a flow file
 * changes, reconciles into the current snapshot and tells listeners when the picture changed.
 */
export class ProjectMonitor {
  readonly project: ProjectDefinition;
  private readonly runner: CommandRunner;
  private readonly clock: () => Date;
  private readonly log: Logger;
  private readonly cadence: Cadence;
  private readonly sessions: Pick<SessionLocator, 'assign'>;
  /** Processes with a session that left the list, newest first, so the owner can still open their session. */
  private ended: EndedProcess[] = [];
  private readonly facts: Facts = {
    files: { facts: null, freshness: unread() }, git: { facts: null, freshness: unread() }, processes: { facts: null, freshness: unread() },
    jobs: { facts: null, freshness: unread() }, board: { facts: null, freshness: unread() }, pulls: { facts: null, freshness: unread() },
  };
  private readonly listeners = new Set<(snapshot: Snapshot) => void>();
  private readonly timers: NodeJS.Timeout[] = [];
  private readonly watchers: FSWatcher[] = [];
  private readonly inFlight = new Map<SourceName, Promise<void>>();
  private debounce: NodeJS.Timeout | null = null;
  private fingerprint = '';
  private readonly gateQuestions: GateQuestionCache = new Map();
  private gateListError: string | null = null;
  /** The config's deprecation warnings last logged, so each is logged once per change. */
  private deprecated = '';
  private current: Snapshot | null = null;
  /** Set by `stop`: a start still making its first reads schedules nothing after it. */
  private stopped = false;
  private readonly settler = new DisagreementSettler();
  private readonly reads: ReadMarks = {
    started: 0,
    completed: { files: 0, git: 0, processes: 0, jobs: 0, board: 0, pulls: 0 },
    failing: { files: false, git: false, processes: false, jobs: false, board: false, pulls: false },
  };

  constructor(dependencies: ProjectMonitorDependencies) {
    this.project = dependencies.project;
    this.runner = dependencies.runner;
    this.clock = dependencies.clock;
    this.log = dependencies.log;
    this.cadence = dependencies.cadence;
    this.sessions = dependencies.sessions ?? noSessions;
  }

  get snapshot(): Snapshot | null { return this.current; }

  /** What an action needs to know about the project right now. The terminal comes from the settings, which the daemon adds. */
  actionContext(): ActionContext {
    const flow = this.facts.files.facts;
    return {
      root: this.project.root, pluginRoot: flow?.pluginRoot ?? null, repo: flow?.config.repo ?? null,
      jobsHost: flow?.config.jobsHost ?? 'claude', pool: flow === null ? [] : poolPaths(this.project.root, flow.config),
      outsideWorktrees: (this.current?.worktrees ?? []).filter((worktree) => worktree.role !== 'pool').map((worktree) => worktree.path),
      // The snapshot's agents, not the raw process list: only processes in this project's worktrees.
      processCwds: (this.current?.agents ?? []).map((agent) => agent.cwd),
      sessions: [
        ...(this.current?.agents ?? []).flatMap((agent) => (agent.session === null ? [] : [{ pid: agent.pid, cwd: agent.cwd, session: agent.session, alive: true }])),
        ...(this.current?.ended ?? []).flatMap((agent) => (agent.session === null ? [] : [{ pid: agent.pid, cwd: agent.cwd, session: agent.session, alive: false }])),
      ],
      terminal: null, installedTerminals: [],
      base: flow?.config.base ?? 'main',
      worktrees: (this.current?.worktrees ?? []).filter((worktree) => worktree.role === 'pool').map((worktree) => ({
        name: worktree.name, path: worktree.path, item: worktree.claim?.item ?? null, claimBase: worktree.claim?.base || null,
        dirtyFiles: worktree.dirtyFiles, behindBase: worktree.behindBase, agentPids: worktree.agents.map((agent) => agent.pid),
      })),
      runItems: (flow?.runs ?? []).map((run) => run.item),
    };
  }

  onChange(listener: (snapshot: Snapshot) => void): () => void {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  async start(): Promise<void> {
    await this.refresh('files');
    await Promise.all([this.refresh('git'), this.refresh('processes'), this.refresh('jobs')]);
    if (this.stopped) return;
    void this.refresh('board');
    void this.refresh('pulls');
    this.schedule('files', this.cadence.filesMs);
    this.schedule('git', this.cadence.gitMs);
    this.schedule('processes', this.cadence.processesMs);
    this.schedule('jobs', this.cadence.jobsMs);
    this.schedule('board', this.cadence.boardMs);
    this.schedule('pulls', this.cadence.pullsMs);
    this.watchFiles();
  }

  stop(): void {
    this.stopped = true;
    for (const timer of this.timers) clearInterval(timer);
    for (const watcher of this.watchers) watcher.close();
    if (this.debounce !== null) clearTimeout(this.debounce);
  }

  /** Re-reads one source now. Concurrent calls for the same source share one read. */
  refresh(source: SourceName): Promise<void> {
    if (!(source in this.facts)) return Promise.resolve();
    const running = this.inFlight.get(source);
    if (running !== undefined) return running;
    const read = this.read(source).finally(() => { this.inFlight.delete(source); });
    this.inFlight.set(source, read);
    return read;
  }

  private schedule(source: SourceName, everyMs: number): void {
    const timer = setInterval(() => { void this.refresh(source); }, everyMs);
    timer.unref();
    this.timers.push(timer);
  }

  private async read(source: SourceName): Promise<void> {
    const startedAt = this.clock();
    this.reads.started += 1;
    const sequence = this.reads.started;
    try {
      const notApplicable = await this.collect(source);
      this.facts[source].freshness = { at: startedAt.toISOString(), ageSeconds: 0, ok: true, error: notApplicable };
      this.reads.completed[source] = Math.max(this.reads.completed[source], sequence);
      this.reads.failing[source] = false;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.facts[source].freshness = { ...this.facts[source].freshness, ok: false, error: message };
      this.reads.failing[source] = true;
      this.log.warn('collect.failed', { project: this.project.id, source, error: message });
    }
    this.rebuild();
  }

  /** Reads one source into the facts. Returns why the source does not apply to this project, or null when it was read. */
  private async collect(source: SourceName): Promise<string | null> {
    const root = this.project.root;
    const flow = this.facts.files.facts;
    switch (source) {
      case 'files': {
        const flowHome = await readFlowHome(root, this.runner, this.gateQuestions);
        this.facts.files.facts = flowHome;
        if (flowHome.gateListError !== null && flowHome.gateListError !== this.gateListError) {
          this.log.warn('gates.list.failed', { project: this.project.id, error: flowHome.gateListError });
        }
        this.gateListError = flowHome.gateListError;
        const deprecated = flowHome.config.deprecated.join('; ');
        if (deprecated !== '' && deprecated !== this.deprecated) this.log.warn('config.deprecated', { project: this.project.id, warning: deprecated });
        this.deprecated = deprecated;
        return flowHome.gateListError === null ? null : `gate questions: ${flowHome.gateListError}`;
      }
      case 'git': this.facts.git.facts = await readGit(root, flow?.config.base ?? 'main', this.runner); return null;
      case 'processes': {
        const listed = await readProcesses(this.runner);
        const sessions = await this.sessions.assign(listed.agents);
        const agents = listed.agents.map((agent, index) => ({ ...agent, session: sessions[index] ?? null }));
        this.noteEnded(agents);
        this.facts.processes.facts = { agents };
        return null;
      }
      case 'jobs':
        if (flow?.pluginRoot == null) throw new Error('no flow plugin found for the project');
        this.facts.jobs.facts = await readJobs(root, flow.pluginRoot, this.runner); return null;
      case 'board':
        if (flow?.pluginRoot == null) throw new Error('no flow plugin found for the project');
        this.facts.board.facts = await readBoard(root, flow.pluginRoot, this.runner); return null;
      case 'pulls':
        if (flow === null) throw new Error('the flow files are not read yet');
        this.facts.pulls.facts = null;
        if (flow.config.adapter !== PULLS_ADAPTER) return `not applicable: adapter ${flow.config.adapter}`;
        if (flow.config.repo === null) return 'not applicable: no github.repo in .flow/config.yaml';
        this.facts.pulls.facts = await readPulls(root, flow.config.repo, this.runner); return null;
    }
  }

  private rebuild(): void {
    const flow = this.facts.files.facts;
    if (flow === null) return;
    const now = this.clock();
    const sources = Object.fromEntries(
      (Object.keys(this.facts) as SourceName[]).map((name) => {
        const freshness = this.facts[name].freshness;
        return [name, { ...freshness, ageSeconds: ageSeconds(freshness.at, now) }];
      }),
    ) as Record<SourceName, Freshness>;
    this.current = reconcile({
      now, project: this.project, flow, git: this.facts.git.facts, processes: this.facts.processes.facts, ended: this.ended,
      jobs: this.facts.jobs.facts, board: this.facts.board.facts, pulls: this.facts.pulls.facts, sources,
      settle: (found) => this.settler.settle(found, this.reads),
    });
    const fingerprint = this.fingerprintOf();
    if (fingerprint === this.fingerprint) return;
    this.fingerprint = fingerprint;
    for (const listener of this.listeners) listener(this.current);
  }

  /** What counts as a change: the facts and the disagreements that settled, without the counters that move on every read. */
  private fingerprintOf(): string {
    const agents = (this.facts.processes.facts?.agents ?? []).map(({ pid, host, cwd, session }) => ({ pid, host, cwd, session: session?.id ?? null }));
    const ended = this.ended.map(({ pid, endedAt }) => [pid, endedAt]);
    const errors = (Object.keys(this.facts) as SourceName[]).map((name) => this.facts[name].freshness.error);
    const disagreements = (this.current?.disagreements ?? []).map(disagreementKey);
    return JSON.stringify([this.facts.files.facts, this.facts.git.facts, agents, ended, this.facts.jobs.facts, this.facts.board.facts, this.facts.pulls.facts, errors, disagreements]);
  }

  /** A process with a session that was listed last time and is gone now has ended; one listed again is not. */
  private noteEnded(agents: ProcessFacts['agents']): void {
    const now = this.clock().toISOString();
    const live = new Set(agents.map((agent) => agent.pid));
    const gone = (this.facts.processes.facts?.agents ?? []).filter((agent) => agent.session !== null && !live.has(agent.pid));
    this.ended = [...gone.map((agent) => ({ ...agent, endedAt: now })), ...this.ended.filter((agent) => !live.has(agent.pid))].slice(0, ENDED_KEPT * 2);
  }

  private watchFiles(): void {
    const flow = this.facts.files.facts;
    if (flow === null) return;
    const flowHome = flowHomeOf(this.project.root);
    const onChange = (changed: string | null): void => {
      const top = changed === null ? '' : changed.split(path.sep)[0] ?? '';
      if (UNWATCHED_FOLDERS.includes(top)) return;
      if (this.debounce !== null) clearTimeout(this.debounce);
      this.debounce = setTimeout(() => { void this.refresh('files').then(() => this.refresh('git')); }, WATCH_DEBOUNCE_MS);
    };
    this.watch(flowHome, true, onChange);
    for (const worktree of poolPaths(this.project.root, flow.config)) this.watch(path.join(worktree, '.flow'), false, onChange);
  }

  private watch(target: string, recursive: boolean, onChange: (changed: string | null) => void): void {
    try {
      const watcher = watch(target, { recursive, persistent: false }, (_event, filename) => onChange(filename === null ? null : String(filename)));
      watcher.on('error', (error) => this.log.warn('watch.failed', { project: this.project.id, target, error: error.message }));
      this.watchers.push(watcher);
    } catch (error) {
      this.log.warn('watch.failed', { project: this.project.id, target, error: error instanceof Error ? error.message : String(error) });
    }
  }
}
