import { randomUUID } from 'node:crypto';
import { closeSync, mkdirSync, openSync } from 'node:fs';
import { appendFile, mkdir, writeFile } from 'node:fs/promises';
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
  onExit(listener: (code: number | null, signal: string | null) => void): void;
  kill(): void;
};

/** Starts a planned process. A detached plan gets its output file and is left to run. */
export type Spawner = (plan: ActionPlan, env: Record<string, string>, outputFile: string) => ProcessHandle;

export type ActionRunnerDependencies = {
  projectId: string;
  /** Read at request time, so a plugin found after start still counts. */
  context: () => ActionContext;
  spawner: Spawner;
  clock: () => Date;
  log: Logger;
  /** Where the audit log and the output files live; never inside a project. */
  stateDir: string;
  /** Called when an action ends, with the sources it asks to re-read. */
  onRefresh: (sources: string[]) => void;
};

export type RequestOutcome = { status: number; body: { action: ActionRecord } | { error: string; action?: ActionRecord } };

const HTTP_ACCEPTED = 202;
const HTTP_BAD_REQUEST = 400;
const HTTP_CONFLICT = 409;
/** How much output the stream carries; the full text waits behind GET .../actions/<id>. */
export const OUTPUT_TAIL_BYTES = 4096;
/** How much output the daemon keeps in memory per action; the file on disk has it all. */
const OUTPUT_KEPT_BYTES = 1024 * 1024;
/** Actions kept in memory for the list and the detail route. */
const RECORDS_KEPT = 200;
export const RECENT_LISTED = 50;
const MAX_RUNNING = 4;
/** How often the stream hears about output still arriving. */
const OUTPUT_EVENT_MS = 500;
const SIGNAL_EXIT = 128;
const ALL_SOURCES = ['files', 'git', 'processes', 'jobs', 'board', 'pulls'];

type Live = { record: ActionRecord; plan: ActionPlan; output: string; handle: ProcessHandle | null; timer: NodeJS.Timeout | null; notify: NodeJS.Timeout | null };

export const childProcessSpawner: Spawner = (plan, env, outputFile) => {
  mkdirSync(path.dirname(outputFile), { recursive: true });
  if (plan.detach) {
    const fd = openSync(outputFile, 'a');
    const child = spawn(plan.command, plan.args, { cwd: plan.cwd, env, detached: true, stdio: ['ignore', fd, fd] });
    child.unref();
    closeSync(fd);
    return { pid: child.pid ?? null, stdout: null, stderr: null, onExit: () => {}, kill: () => {} };
  }
  const child = spawn(plan.command, plan.args, { cwd: plan.cwd, env, stdio: ['ignore', 'pipe', 'pipe'] });
  return {
    pid: child.pid ?? null,
    stdout: child.stdout,
    stderr: child.stderr,
    onExit: (listener) => { child.on('error', (error) => listener(null, error.message)); child.on('exit', listener); },
    kill: () => { child.kill('SIGTERM'); },
  };
};

export function isActionKind(value: unknown): value is ActionKind {
  return typeof value === 'string' && (ACTION_KINDS as string[]).includes(value);
}

/**
 * Runs actions for one project. Each action is one process from `planAction`, with a lock so two
 * cannot touch the same item, worktree, job or PR at once. Output streams to listeners as it
 * arrives and the whole record lands in the audit log when the action ends.
 */
export class ActionRunner {
  private readonly deps: ActionRunnerDependencies;
  private readonly records: ActionRecord[] = [];
  private readonly outputs = new Map<string, string>();
  private readonly live = new Map<string, Live>();
  private readonly listeners = new Set<(record: ActionRecord) => void>();
  private readonly writes = new Set<Promise<void>>();

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
    if (!isActionKind(kind)) return { status: HTTP_BAD_REQUEST, body: { error: `unknown action kind: ${String(kind)}` } };
    const cleanArgs = argumentsOf(args);
    if (cleanArgs === null) return { status: HTTP_BAD_REQUEST, body: { error: 'args must be an object of strings' } };
    const planned = planAction(kind, cleanArgs, this.deps.context());
    const now = this.deps.clock().toISOString();
    const record: ActionRecord = {
      id: randomUUID().slice(0, 8), kind, args: cleanArgs, state: 'queued', command: [], lock: null,
      requestedAt: now, startedAt: null, endedAt: null, exitCode: null, timedOut: false, outputTail: '', outputBytes: 0,
    };
    if (!planned.ok) return { status: HTTP_BAD_REQUEST, body: { error: planned.error, action: this.reject(record, planned.error) } };
    const { plan } = planned;
    record.command = plan.command === '' ? [] : [plan.command, ...plan.args];
    record.lock = plan.lock === '' ? null : plan.lock;
    if (kind === 'refresh') {
      const source = cleanArgs['source'];
      const wanted = source === undefined || source === '' ? ALL_SOURCES : [source];
      if (!wanted.every((name) => ALL_SOURCES.includes(name))) return { status: HTTP_BAD_REQUEST, body: { error: `unknown source: ${source}`, action: this.reject(record, `unknown source: ${source}`) } };
      return { status: HTTP_ACCEPTED, body: { action: this.refreshNow(record, wanted) } };
    }
    const held = [...this.live.values()].find((other) => other.record.lock === record.lock);
    if (held !== undefined) return { status: HTTP_CONFLICT, body: { error: `${record.lock} is held by action ${held.record.id} (${held.record.kind})`, action: this.reject(record, 'lock held') } };
    if (this.live.size >= MAX_RUNNING) return { status: HTTP_CONFLICT, body: { error: `${MAX_RUNNING} actions are running already`, action: this.reject(record, 'too many running') } };
    this.remember(record);
    this.start(record, plan);
    return { status: HTTP_ACCEPTED, body: { action: record } };
  }

  /** Ends every running action; the daemon is shutting down. Detached runs keep going by design. */
  stopAll(): void {
    for (const entry of this.live.values()) entry.handle?.kill();
  }

  /** Every audit write so far has landed. Tests wait on this; the server never needs to. */
  async whenIdle(): Promise<void> {
    await Promise.all([...this.writes]);
  }

  private refreshNow(record: ActionRecord, wanted: string[]): ActionRecord {
    const now = this.deps.clock().toISOString();
    Object.assign(record, { state: 'done', startedAt: now, endedAt: now, exitCode: 0, outputTail: `refreshing ${wanted.join(', ')}\n` });
    record.outputBytes = record.outputTail.length;
    this.remember(record);
    this.outputs.set(record.id, record.outputTail);
    this.deps.onRefresh(wanted);
    this.emit(record);
    this.audit(record);
    return record;
  }

  private reject(record: ActionRecord, reason: string): ActionRecord {
    const now = this.deps.clock().toISOString();
    Object.assign(record, { state: 'rejected', endedAt: now, outputTail: `${reason}\n`, outputBytes: reason.length + 1 });
    this.remember(record);
    this.outputs.set(record.id, record.outputTail);
    this.emit(record);
    this.audit(record);
    return record;
  }

  private start(record: ActionRecord, plan: ActionPlan): void {
    const entry: Live = { record, plan, output: '', handle: null, timer: null, notify: null };
    this.live.set(record.id, entry);
    record.startedAt = this.deps.clock().toISOString();
    record.state = 'running';
    try {
      entry.handle = this.deps.spawner(plan, scriptEnvironment(), this.outputFile(record.id));
    } catch (error) {
      this.finish(entry, null, error instanceof Error ? error.message : String(error));
      return;
    }
    this.emit(record);
    this.deps.log.info('action.start', { project: this.deps.projectId, id: record.id, kind: record.kind, pid: entry.handle.pid, command: record.command.join(' ') });
    if (plan.detach) { this.append(entry, `started pid ${entry.handle.pid ?? '?'}; output in ${this.outputFile(record.id)}\n`); this.finish(entry, 0, null); return; }
    entry.handle.stdout?.on('data', (chunk: Buffer | string) => this.append(entry, chunk.toString()));
    entry.handle.stderr?.on('data', (chunk: Buffer | string) => this.append(entry, chunk.toString()));
    entry.handle.onExit((code, signal) => this.finish(entry, code, signal));
    if (plan.timeoutMs > 0) {
      entry.timer = setTimeout(() => { record.timedOut = true; this.append(entry, `\nconsole: no answer after ${plan.timeoutMs / 1000}s, stopping it\n`); entry.handle?.kill(); }, plan.timeoutMs);
      entry.timer.unref();
    }
  }

  private append(entry: Live, text: string): void {
    const { record } = entry;
    record.outputBytes += Buffer.byteLength(text);
    if (entry.output.length < OUTPUT_KEPT_BYTES) entry.output += text.slice(0, OUTPUT_KEPT_BYTES - entry.output.length);
    record.outputTail = (record.outputTail + text).slice(-OUTPUT_TAIL_BYTES);
    if (entry.notify !== null) return;
    entry.notify = setTimeout(() => { entry.notify = null; if (this.live.has(record.id)) this.emit(record); }, OUTPUT_EVENT_MS);
    entry.notify.unref();
  }

  private finish(entry: Live, code: number | null, signal: string | null): void {
    const { record } = entry;
    if (!this.live.has(record.id)) return;
    this.live.delete(record.id);
    if (entry.timer !== null) clearTimeout(entry.timer);
    if (entry.notify !== null) clearTimeout(entry.notify);
    if (signal !== null && code === null) this.append(entry, `\nconsole: ${signal}\n`);
    record.endedAt = this.deps.clock().toISOString();
    record.exitCode = code ?? (signal === null ? null : SIGNAL_EXIT);
    record.state = code === 0 ? 'done' : 'failed';
    this.outputs.set(record.id, entry.output);
    this.emit(record);
    this.deps.log.info('action.end', { project: this.deps.projectId, id: record.id, kind: record.kind, state: record.state, exit: record.exitCode, timedOut: record.timedOut });
    if (entry.plan.refresh.length > 0) this.deps.onRefresh(entry.plan.refresh);
    this.audit(record, entry.output);
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

  /** One JSON line per finished action in <stateDir>/<project>/actions.jsonl, and its output beside it. */
  private audit(record: ActionRecord, output?: string): void {
    const write = this.write(record, output).finally(() => { this.writes.delete(write); });
    this.writes.add(write);
  }

  private async write(record: ActionRecord, output?: string): Promise<void> {
    const folder = path.join(this.deps.stateDir, this.deps.projectId);
    try {
      await mkdir(path.join(folder, 'actions'), { recursive: true });
      if (output !== undefined) await writeFile(this.outputFile(record.id), output);
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
