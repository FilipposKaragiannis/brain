import { randomUUID } from 'node:crypto';
import { closeSync, mkdirSync, openSync } from 'node:fs';
import { appendFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import type { Readable } from 'node:stream';
import { spawn } from 'node:child_process';
import type { ActionContext, ActionPlan } from './actionPlan.ts';
import { ACTION_KINDS, planAction } from './actionPlan.ts';
import { scriptEnvironment } from './collectors/exec.ts';
import type { Logger } from './log.ts';
import type { ActionKind, ActionRecord } from './snapshot.ts';

/** A started process, as much of it as the runner needs. Injected so tests never fork. */
export type ProcessHandle = {
  pid: number | null;
  stdout: Readable | null;
  stderr: Readable | null;
  /** Fires once, after the process ended and its output streams closed, or when it could not start. */
  onClose(listener: (code: number | null, signal: string | null) => void): void;
  /** Signals the whole process group, so a script's children go with it. */
  kill(signal: 'SIGTERM' | 'SIGKILL'): void;
};

/** Starts a planned process. A detached plan writes to its output file and outlives the daemon. */
export type Spawner = (plan: ActionPlan, env: Record<string, string>, outputFile: string) => ProcessHandle;

/** Timers, injected so a test can fire a timeout without waiting for it. */
export type Scheduler = {
  after(ms: number, task: () => void): object;
  cancel(handle: object): void;
};

export type ActionRunnerDependencies = {
  projectId: string;
  /** Read at request time, so a plugin found after start still counts. */
  context: () => ActionContext;
  spawner: Spawner;
  scheduler: Scheduler;
  clock: () => Date;
  log: Logger;
  /** Where the audit log and the output files live; never inside a project. */
  stateDir: string;
  /** Called when an action ends, with the sources it asks to re-read. */
  onRefresh: (sources: string[]) => void;
};

export type RequestOutcome = { status: number; body: { action: ActionRecord } | { error: string; action: ActionRecord } };

const HTTP_ACCEPTED = 202;
const HTTP_BAD_REQUEST = 400;
const HTTP_CONFLICT = 409;
/** How much output the stream carries; the full text waits behind GET .../actions/<id>. */
export const OUTPUT_TAIL_CHARS = 4096;
/** How much output the daemon keeps in memory per action; the file on disk has it all. */
const OUTPUT_KEPT_CHARS = 256 * 1024;
/** Actions kept in memory for the list and the detail route. */
const RECORDS_KEPT = 200;
export const RECENT_LISTED = 50;
const MAX_RUNNING = 4;
/** How often the stream hears about output still arriving. */
const OUTPUT_EVENT_MS = 500;
/** How long a process gets after SIGTERM before SIGKILL. */
export const KILL_GRACE_MS = 10000;
const SIGNAL_EXIT = 128;
const ID_CHARS = 12;

type Live = {
  record: ActionRecord;
  plan: ActionPlan;
  output: string;
  handle: ProcessHandle | null;
  timeout: object | null;
  grace: object | null;
  notify: object | null;
};

export const realScheduler: Scheduler = {
  after: (ms, task) => { const timer = setTimeout(task, ms); timer.unref(); return timer; },
  cancel: (handle) => { clearTimeout(handle as NodeJS.Timeout); },
};

/**
 * Every action runs as the leader of its own process group, so a kill reaches the script's
 * children too. A detached plan also writes to its own file and is unref'd, so a run lasting
 * hours survives a daemon restart. In both cases the daemon hears when the process ends.
 */
export const childProcessSpawner: Spawner = (plan, env, outputFile) => {
  mkdirSync(path.dirname(outputFile), { recursive: true });
  const fd = plan.detach ? openSync(outputFile, 'a') : null;
  const child = spawn(plan.command, plan.args, { cwd: plan.cwd, env, detached: true, stdio: fd === null ? ['ignore', 'pipe', 'pipe'] : ['ignore', fd, fd] });
  if (fd !== null) { child.unref(); closeSync(fd); }
  let closed = false;
  return {
    pid: child.pid ?? null,
    stdout: child.stdout,
    stderr: child.stderr,
    onClose: (listener) => {
      const once = (code: number | null, signal: string | null): void => { if (!closed) { closed = true; listener(code, signal); } };
      child.on('error', (error) => once(null, error.message));
      child.on('close', once);
    },
    kill: (signal) => {
      if (child.pid === undefined) return;
      try { process.kill(-child.pid, signal); } catch { child.kill(signal); }
    },
  };
};

export function isActionKind(value: unknown): value is ActionKind {
  return typeof value === 'string' && (ACTION_KINDS as string[]).includes(value);
}

/**
 * Runs actions for one project. Each action is one process from `planAction`, with a lock so two
 * cannot touch the same item, worktree, job or PR at once. Output streams to listeners as it
 * arrives and the record lands in the audit log when the action starts and when it ends.
 */
export class ActionRunner {
  private readonly deps: ActionRunnerDependencies;
  private readonly records: ActionRecord[] = [];
  private readonly outputs = new Map<string, string>();
  private readonly live = new Map<string, Live>();
  private readonly listeners = new Set<(record: ActionRecord) => void>();
  private readonly writes = new Set<Promise<void>>();
  /** Second reads waiting for a handed-on job to show; cancelled when the daemon stops. */
  private readonly refreshesAgain = new Set<object>();

  constructor(dependencies: ActionRunnerDependencies) { this.deps = dependencies; }

  onChange(listener: (record: ActionRecord) => void): () => void {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  /** The recent actions, newest first, without their full output. */
  list(): ActionRecord[] { return this.records.slice(0, RECENT_LISTED); }

  /** One action with its full output, or null. */
  get(id: string): ActionRecord | null {
    const record = this.records.find((entry) => entry.id === id);
    if (record === undefined) return null;
    return { ...record, output: this.live.get(id)?.output ?? this.outputs.get(id) ?? '' };
  }

  /** Validates, plans, locks and starts one action. The outcome maps straight to an HTTP reply. */
  request(kind: unknown, args: unknown): RequestOutcome {
    const now = this.deps.clock().toISOString();
    const record: ActionRecord = {
      id: randomUUID().replaceAll('-', '').slice(0, ID_CHARS), kind: 'refresh', args: {}, state: 'running', command: [], locks: [],
      requestedAt: now, startedAt: null, endedAt: null, exitCode: null, timedOut: false, outcome: null, outputTail: '', outputBytes: 0,
    };
    if (!isActionKind(kind)) return { status: HTTP_BAD_REQUEST, body: { error: `unknown action kind: ${String(kind)}`, action: this.reject(record, 'unknown kind') } };
    record.kind = kind;
    const cleanArgs = argumentsOf(args);
    if (cleanArgs === null) return { status: HTTP_BAD_REQUEST, body: { error: 'args must be an object of strings', action: this.reject(record, 'bad args') } };
    record.args = cleanArgs;
    const planned = planAction(kind, cleanArgs, this.deps.context());
    if (!planned.ok) return { status: HTTP_BAD_REQUEST, body: { error: planned.error, action: this.reject(record, planned.error) } };
    const { plan } = planned;
    record.command = plan.command === '' ? [] : [plan.command, ...plan.args];
    record.locks = plan.locks;
    if (kind === 'refresh') return { status: HTTP_ACCEPTED, body: { action: this.refreshNow(record, plan.refresh) } };
    const held = [...this.live.values()].find((other) => other.record.locks.some((lock) => record.locks.includes(lock)));
    if (held !== undefined) {
      const shared = held.record.locks.filter((lock) => record.locks.includes(lock)).join(', ');
      return { status: HTTP_CONFLICT, body: { error: `${shared} is held by action ${held.record.id} (${held.record.kind})`, action: this.reject(record, `lock held: ${shared}`) } };
    }
    if (this.live.size >= MAX_RUNNING) return { status: HTTP_CONFLICT, body: { error: `${MAX_RUNNING} actions are running already`, action: this.reject(record, 'too many running') } };
    this.remember(record);
    this.start(record, plan);
    return { status: HTTP_ACCEPTED, body: { action: { ...record } } };
  }

  /** Ends every attached action and drops the second reads still waiting; the daemon is shutting down. Detached runs keep going by design. */
  stopAll(): void {
    for (const entry of this.live.values()) if (!entry.plan.detach) entry.handle?.kill('SIGTERM');
    for (const handle of this.refreshesAgain) this.deps.scheduler.cancel(handle);
    this.refreshesAgain.clear();
  }

  /** Every audit write so far has landed. Tests wait on this; the server never needs to. */
  async whenIdle(): Promise<void> {
    await Promise.all([...this.writes]);
  }

  private refreshNow(record: ActionRecord, wanted: string[]): ActionRecord {
    const now = this.deps.clock().toISOString();
    const text = `refreshing ${wanted.join(', ')}\n`;
    Object.assign(record, { state: 'done', outcome: 'finished', startedAt: now, endedAt: now, exitCode: 0, outputTail: text, outputBytes: Buffer.byteLength(text) });
    this.remember(record);
    this.outputs.set(record.id, text);
    this.deps.onRefresh(wanted);
    this.emit(record);
    this.audit(record, null);
    return record;
  }

  private reject(record: ActionRecord, reason: string): ActionRecord {
    const text = `${reason}\n`;
    Object.assign(record, { state: 'rejected', endedAt: this.deps.clock().toISOString(), outputTail: text, outputBytes: Buffer.byteLength(text) });
    this.remember(record);
    this.outputs.set(record.id, text);
    this.emit(record);
    this.audit(record, null);
    return record;
  }

  private start(record: ActionRecord, plan: ActionPlan): void {
    const entry: Live = { record, plan, output: '', handle: null, timeout: null, grace: null, notify: null };
    this.live.set(record.id, entry);
    record.startedAt = this.deps.clock().toISOString();
    try {
      entry.handle = this.deps.spawner(plan, scriptEnvironment(), this.outputFile(record.id));
    } catch (error) {
      this.append(entry, `console: could not start: ${error instanceof Error ? error.message : String(error)}\n`);
      this.finish(entry, null, null);
      return;
    }
    this.deps.log.info('action.start', { project: this.deps.projectId, id: record.id, kind: record.kind, pid: entry.handle.pid, command: record.command.join(' ') });
    this.audit(record, null);
    if (plan.detach) {
      record.outcome = 'started';
      this.append(entry, `started pid ${entry.handle.pid ?? '?'}; output in ${this.outputFile(record.id)}\n`);
    }
    this.emit(record);
    entry.handle.stdout?.on('data', (chunk: Buffer | string) => this.append(entry, chunk.toString()));
    entry.handle.stderr?.on('data', (chunk: Buffer | string) => this.append(entry, chunk.toString()));
    entry.handle.onClose((code, signal) => { void this.finish(entry, code, signal); });
    if (plan.timeoutMs > 0) {
      entry.timeout = this.deps.scheduler.after(plan.timeoutMs, () => {
        record.timedOut = true;
        this.append(entry, `\nconsole: no answer after ${plan.timeoutMs / 1000}s, stopping it\n`);
        entry.handle?.kill('SIGTERM');
        entry.grace = this.deps.scheduler.after(KILL_GRACE_MS, () => { this.append(entry, 'console: still running, killed\n'); entry.handle?.kill('SIGKILL'); });
      });
    }
  }

  private append(entry: Live, text: string): void {
    const { record } = entry;
    record.outputBytes += Buffer.byteLength(text);
    if (entry.output.length < OUTPUT_KEPT_CHARS) entry.output += text.slice(0, OUTPUT_KEPT_CHARS - entry.output.length);
    record.outputTail = (record.outputTail + text).slice(-OUTPUT_TAIL_CHARS);
    if (entry.notify !== null) return;
    entry.notify = this.deps.scheduler.after(OUTPUT_EVENT_MS, () => { entry.notify = null; if (this.live.has(record.id)) this.emit(record); });
  }

  private async finish(entry: Live, code: number | null, signal: string | null): Promise<void> {
    const { record } = entry;
    if (!this.live.has(record.id)) return;
    this.live.delete(record.id);
    for (const handle of [entry.timeout, entry.grace, entry.notify]) if (handle !== null) this.deps.scheduler.cancel(handle);
    if (signal !== null && code === null) this.append(entry, `\nconsole: ${signal}\n`);
    if (entry.plan.detach && entry.handle !== null) entry.output = await this.detachedOutput(record.id, entry.output);
    record.endedAt = this.deps.clock().toISOString();
    record.exitCode = code ?? (signal === null ? null : SIGNAL_EXIT);
    record.state = code === 0 && !record.timedOut ? 'done' : 'failed';
    record.outcome = record.state === 'done' ? entry.plan.outcome : null;
    this.outputs.set(record.id, entry.output);
    this.emit(record);
    this.deps.log.info('action.end', { project: this.deps.projectId, id: record.id, kind: record.kind, state: record.state, exit: record.exitCode, timedOut: record.timedOut });
    if (entry.plan.refresh.length > 0) this.refreshAfter(entry.plan);
    this.audit(record, entry.plan.detach ? null : entry.output);
  }

  /** Re-reads what the plan changed now, and once more after `refreshAgainMs` for work that was handed on. */
  private refreshAfter(plan: ActionPlan): void {
    this.deps.onRefresh(plan.refresh);
    if (plan.refreshAgainMs === null) return;
    const handle = this.deps.scheduler.after(plan.refreshAgainMs, () => { this.refreshesAgain.delete(handle); this.deps.onRefresh(plan.refresh); });
    this.refreshesAgain.add(handle);
  }

  /** A detached run wrote its own file; the record keeps the start line and the file's tail. */
  private async detachedOutput(id: string, startLine: string): Promise<string> {
    try {
      const written = await readFile(this.outputFile(id), 'utf8');
      return startLine + written.slice(-OUTPUT_KEPT_CHARS);
    } catch { return startLine; }
  }

  private remember(record: ActionRecord): void {
    this.records.unshift(record);
    while (this.records.length > RECORDS_KEPT) {
      const dropped = this.records.pop();
      if (dropped !== undefined) this.outputs.delete(dropped.id);
    }
  }

  private emit(record: ActionRecord): void {
    for (const listener of this.listeners) listener({ ...record });
  }

  private outputFile(id: string): string {
    return path.join(this.deps.stateDir, this.deps.projectId, 'actions', `${id}.log`);
  }

  /** One JSON line per start and per end in <stateDir>/<project>/actions.jsonl, the output beside it. */
  private audit(record: ActionRecord, output: string | null): void {
    const write = this.write({ ...record }, output).finally(() => { this.writes.delete(write); });
    this.writes.add(write);
  }

  private async write(record: ActionRecord, output: string | null): Promise<void> {
    const folder = path.join(this.deps.stateDir, this.deps.projectId);
    try {
      await mkdir(path.join(folder, 'actions'), { recursive: true });
      if (output !== null) await writeFile(this.outputFile(record.id), output);
      const { outputTail: _tail, output: _output, ...line } = record;
      await appendFile(path.join(folder, 'actions.jsonl'), JSON.stringify(line) + '\n');
    } catch (error) {
      this.deps.log.warn('audit.failed', { project: this.deps.projectId, id: record.id, error: error instanceof Error ? error.message : String(error) });
    }
  }
}

function argumentsOf(value: unknown): Record<string, string> | null {
  if (value === undefined || value === null) return {};
  if (typeof value !== 'object' || Array.isArray(value)) return null;
  const clean: Record<string, string> = {};
  for (const [key, entry] of Object.entries(value as Record<string, unknown>)) {
    if (typeof entry !== 'string') return null;
    clean[key] = entry;
  }
  return clean;
}
