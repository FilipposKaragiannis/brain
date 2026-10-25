import { PassThrough } from 'node:stream';
import type { ActionPlan } from '../src/actionPlan.ts';
import type { ProcessHandle, Spawner } from '../src/actions.ts';

export type FakeProcess = {
  plan: ActionPlan;
  env: Record<string, string>;
  outputFile: string;
  stdout: PassThrough;
  stderr: PassThrough;
  killed: boolean;
  exit(code: number | null, signal?: string | null): void;
};

/** A spawner that forks nothing: each call hands the test a process it drives by hand. */
export function fakeSpawner(): { spawner: Spawner; processes: FakeProcess[] } {
  const processes: FakeProcess[] = [];
  const spawner: Spawner = (plan, env, outputFile) => {
    const stdout = new PassThrough();
    const stderr = new PassThrough();
    let onExit: (code: number | null, signal: string | null) => void = () => {};
    const fake: FakeProcess = {
      plan, env, outputFile, stdout, stderr, killed: false,
      exit: (code, signal = null) => { stdout.end(); stderr.end(); setImmediate(() => onExit(code, signal)); },
    };
    processes.push(fake);
    const handle: ProcessHandle = {
      pid: 4000 + processes.length,
      stdout: plan.detach ? null : stdout,
      stderr: plan.detach ? null : stderr,
      onExit: (listener) => { onExit = listener; },
      kill: () => { fake.killed = true; fake.exit(null, 'SIGTERM'); },
    };
    return handle;
  };
  return { spawner, processes };
}

export const settle = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 5));
