import { PassThrough } from 'node:stream';
import { mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import type { ActionPlan } from '../src/actionPlan.ts';
import type { ProcessHandle, Scheduler, Spawner } from '../src/actions.ts';

export type FakeProcess = {
  plan: ActionPlan;
  env: Record<string, string>;
  outputFile: string;
  stdout: PassThrough;
  stderr: PassThrough;
  signals: string[];
  /** When true the process ignores SIGTERM, like a shell with a trap, and only SIGKILL ends it. */
  ignoresTerm: boolean;
  /** Ends the process: the streams close first, then the close event fires, as node does. */
  exit(code: number | null, signal: string | null): void;
  /** Output that arrives after exit but before close, as a grandchild's output does. */
  lateOutput(text: string): void;
};

export type FakeSpawnerOptions = {
  /** The error a spawn throws, as a missing cwd does. */
  failWith: string | null;
  /** What a detached process writes to its output file before it ends. */
  detachedOutput: string;
};

/** A spawner that forks nothing: each call hands the test a process it drives by hand. */
export function fakeSpawner(options: FakeSpawnerOptions): { spawner: Spawner; processes: FakeProcess[] } {
  const processes: FakeProcess[] = [];
  const spawner: Spawner = (plan, env, outputFile) => {
    if (options.failWith !== null) throw new Error(options.failWith);
    const stdout = new PassThrough();
    const stderr = new PassThrough();
    let onClose: (code: number | null, signal: string | null) => void = () => {};
    let closed = false;
    const fake: FakeProcess = {
      plan, env, outputFile, stdout, stderr, signals: [], ignoresTerm: false,
      exit: (code, signal) => {
        if (closed) return;
        closed = true;
        if (plan.detach) { mkdirSync(path.dirname(outputFile), { recursive: true }); writeFileSync(outputFile, options.detachedOutput); }
        stdout.end();
        stderr.end();
        setImmediate(() => onClose(code, signal));
      },
      lateOutput: (text) => { stdout.write(text); },
    };
    processes.push(fake);
    const handle: ProcessHandle = {
      pid: 4000 + processes.length,
      stdout: plan.detach ? null : stdout,
      stderr: plan.detach ? null : stderr,
      onClose: (listener) => { onClose = listener; },
      kill: (signal) => {
        fake.signals.push(signal);
        if (signal === 'SIGTERM' && fake.ignoresTerm) return;
        fake.exit(null, signal);
      },
    };
    return handle;
  };
  return { spawner, processes };
}

export const plainSpawner = (): { spawner: Spawner; processes: FakeProcess[] } => fakeSpawner({ failWith: null, detachedOutput: '' });

/** Timers the test fires by hand, by the delay they were asked for. */
export function fakeScheduler(): { scheduler: Scheduler; fire(ms: number): number; pending(): number[] } {
  const timers = new Map<object, { ms: number; task: () => void }>();
  return {
    scheduler: {
      after: (ms, task) => { const handle = {}; timers.set(handle, { ms, task }); return handle; },
      cancel: (handle) => { timers.delete(handle); },
    },
    fire: (ms) => {
      let fired = 0;
      for (const [handle, timer] of [...timers]) if (timer.ms === ms) { timers.delete(handle); timer.task(); fired += 1; }
      return fired;
    },
    pending: () => [...timers.values()].map((timer) => timer.ms),
  };
}

export const settle = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 10));
