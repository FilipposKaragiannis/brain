import { watch } from 'node:fs';
import type { FSWatcher } from 'node:fs';
import path from 'node:path';
import type { BoardFacts } from './collectors/board.ts';
import { readBoard } from './collectors/board.ts';
import type { CommandRunner } from './collectors/exec.ts';
import type { FlowHomeFacts } from './collectors/flowHome.ts';
import { flowHomeOf, poolPaths, readFlowHome } from './collectors/flowHome.ts';
import type { GitFacts } from './collectors/git.ts';
import { readGit } from './collectors/git.ts';
import type { JobFacts } from './collectors/jobs.ts';
import { readJobs } from './collectors/jobs.ts';
import type { ProcessFacts } from './collectors/processes.ts';
import { readProcesses } from './collectors/processes.ts';
import type { ActionContext } from './actionPlan.ts';
import type { Logger } from './log.ts';
import { ageSeconds, reconcile } from './reconcile.ts';
import type { Freshness, Snapshot, SourceName } from './snapshot.ts';

/** How often each source is re-read, in milliseconds. File changes also trigger `files` and `git` at once. */
export type Cadence = { filesMs: number; gitMs: number; processesMs: number; jobsMs: number; boardMs: number };

export const DEFAULT_CADENCE: Cadence = { filesMs: 30000, gitMs: 30000, processesMs: 10000, jobsMs: 60000, boardMs: 120000 };

const WATCH_DEBOUNCE_MS = 500;
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
};

export type ProjectMonitorDependencies = {
  project: ProjectDefinition;
  runner: CommandRunner;
  clock: () => Date;
  log: Logger;
  cadence: Cadence;
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
  private readonly facts: Facts = {
    files: { facts: null, freshness: unread() }, git: { facts: null, freshness: unread() }, processes: { facts: null, freshness: unread() },
    jobs: { facts: null, freshness: unread() }, board: { facts: null, freshness: unread() },
  };
  private readonly listeners = new Set<(snapshot: Snapshot) => void>();
  private readonly timers: NodeJS.Timeout[] = [];
  private readonly watchers: FSWatcher[] = [];
  private readonly inFlight = new Map<SourceName, Promise<void>>();
  private debounce: NodeJS.Timeout | null = null;
  private fingerprint = '';
  private current: Snapshot | null = null;

  constructor(dependencies: ProjectMonitorDependencies) {
    this.project = dependencies.project;
    this.runner = dependencies.runner;
    this.clock = dependencies.clock;
    this.log = dependencies.log;
    this.cadence = dependencies.cadence;
  }

  get snapshot(): Snapshot | null { return this.current; }

  /** What an action needs to know about the project right now. */
  actionContext(): ActionContext {
    const flow = this.facts.files.facts;
    return {
      root: this.project.root, pluginRoot: flow?.pluginRoot ?? null, repo: flow?.config.repo ?? null,
      jobsHost: flow?.config.jobsHost ?? 'claude', pool: flow === null ? [] : poolPaths(this.project.root, flow.config),
    };
  }

  onChange(listener: (snapshot: Snapshot) => void): () => void {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  async start(): Promise<void> {
    await this.refresh('files');
    await Promise.all([this.refresh('git'), this.refresh('processes'), this.refresh('jobs')]);
    void this.refresh('board');
    this.schedule('files', this.cadence.filesMs);
    this.schedule('git', this.cadence.gitMs);
    this.schedule('processes', this.cadence.processesMs);
    this.schedule('jobs', this.cadence.jobsMs);
    this.schedule('board', this.cadence.boardMs);
    this.watchFiles();
  }

  stop(): void {
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
    try {
      await this.collect(source);
      this.facts[source].freshness = { at: startedAt.toISOString(), ageSeconds: 0, ok: true, error: null };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      this.facts[source].freshness = { ...this.facts[source].freshness, ok: false, error: message };
      this.log.warn('collect.failed', { project: this.project.id, source, error: message });
    }
    this.rebuild();
  }

  private async collect(source: SourceName): Promise<void> {
    const root = this.project.root;
    const flow = this.facts.files.facts;
    switch (source) {
      case 'files': this.facts.files.facts = await readFlowHome(root, this.runner); return;
      case 'git': this.facts.git.facts = await readGit(root, flow?.config.base ?? 'main', this.runner); return;
      case 'processes': this.facts.processes.facts = await readProcesses(this.runner); return;
      case 'jobs':
        if (flow?.pluginRoot == null) throw new Error('no flow plugin found for the project');
        this.facts.jobs.facts = await readJobs(root, flow.pluginRoot, this.runner); return;
      case 'board':
        if (flow?.pluginRoot == null) throw new Error('no flow plugin found for the project');
        this.facts.board.facts = await readBoard(root, flow.pluginRoot, this.runner); return;
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
      now, project: this.project, flow, git: this.facts.git.facts, processes: this.facts.processes.facts,
      jobs: this.facts.jobs.facts, board: this.facts.board.facts, sources,
    });
    const fingerprint = this.fingerprintOf();
    if (fingerprint === this.fingerprint) return;
    this.fingerprint = fingerprint;
    for (const listener of this.listeners) listener(this.current);
  }

  /** What counts as a change: the facts, without the counters that move on every read. */
  private fingerprintOf(): string {
    const agents = (this.facts.processes.facts?.agents ?? []).map(({ pid, host, cwd }) => ({ pid, host, cwd }));
    const errors = (Object.keys(this.facts) as SourceName[]).map((name) => this.facts[name].freshness.error);
    return JSON.stringify([this.facts.files.facts, this.facts.git.facts, agents, this.facts.jobs.facts, this.facts.board.facts, errors]);
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
