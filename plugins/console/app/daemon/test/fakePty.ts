import { setImmediate as tick } from 'node:timers/promises';
import type { PaneLaunch } from '../src/panePlan.ts';
import type { PaneSize } from '../src/paneProtocol.ts';
import type { PtyHandle, PtySpawner } from '../src/panes.ts';

/** One pty the fake spawner started: what it runs, what reached it, and controls the test drives. */
export type FakePty = {
  launch: PaneLaunch;
  environment: Record<string, string>;
  /** The terminal's current size: the spawn size, then the last resize. */
  size: PaneSize;
  /** Every chunk typed into the pty, in order. */
  received: Uint8Array[];
  paused: boolean;
  /** Whether the master is closed. */
  closed: boolean;
  /** Whether the process has ended. */
  exited: boolean;
  /** When true the process ignores SIGHUP, as `nohup` does, and only SIGKILL ends it. */
  ignoresHangUp: boolean;
  /**
   * When true the process leaves a child in its process group that ignores SIGHUP, as a resumed
   * agent may: the group still runs after the process ended, until SIGKILL reaches it.
   */
  childIgnoresHangUp: boolean;
  /**
   * When true the process leaves a child in its process group that ends on SIGHUP: the group
   * still runs after the process ended, until any signal reaches it.
   */
  childEndsOnHangUp: boolean;
  /** When true the child left in the group has ended, by itself or by a signal, so the group is empty. */
  childEnded: boolean;
  /**
   * Whether someone else's process still runs: once the group is empty the system may hand its id
   * to another process, which any signal sent to the emptied group then ends.
   */
  someoneElsesProcessRunning: boolean;
  /** When true each signal lands a turn of the event loop later, once the process table was listed, as on a busy system. */
  slowProcessTable: boolean;
  /** When true a process a signal ends tells its exit a turn of the event loop later, as node-pty does once it read the master's end. */
  exitToldLate: boolean;
  /** Whether anything still runs in the process group: the process or the child it left. */
  groupRunning(): boolean;
  /** Bytes the process writes to the terminal. */
  emit(bytes: Uint8Array): void;
  /** Ends the process. */
  exit(code: number | null, signal: string | null): void;
  /**
   * The process writes its last chunks and ends. As with node-pty, a paused pty holds what the
   * kernel still has: the chunks, then the exit, reach the listeners only as the pty reads on.
   */
  finish(tail: Uint8Array[], code: number): void;
};

/** A spawner that forks nothing: each spawn hands the test a pty it drives by hand, or the refusal it was given. */
export function fakePty(refusal: string | null): { spawner: PtySpawner; ptys: FakePty[] } {
  const ptys: FakePty[] = [];
  const spawner: PtySpawner = (launch, size, environment) => {
    if (refusal !== null) return { ok: false, error: refusal };
    const outputListeners: ((bytes: Uint8Array) => void)[] = [];
    const exitListeners: ((code: number | null, signal: string | null) => void)[] = [];
    /** What an ended process left in the terminal that a paused pty has not read yet. */
    const unread: { tail: Uint8Array[]; code: number | null } = { tail: [], code: null };
    let processEnded = false;
    const readOn = (): void => {
      while (!fake.paused && unread.tail.length > 0) fake.emit(unread.tail.shift()!);
      if (!fake.paused && processEnded) fake.exit(unread.code, null);
    };
    const fake: FakePty = {
      launch, environment, size: { ...size }, received: [], paused: false, closed: false, exited: false, ignoresHangUp: false, childIgnoresHangUp: false, childEndsOnHangUp: false, childEnded: false, someoneElsesProcessRunning: true, slowProcessTable: false, exitToldLate: false,
      groupRunning: () => !fake.exited || ((fake.childIgnoresHangUp || fake.childEndsOnHangUp) && !fake.childEnded),
      emit: (bytes) => { for (const listener of outputListeners) listener(bytes); },
      exit: (code, signal) => {
        if (fake.exited) return;
        fake.exited = true;
        for (const listener of exitListeners) listener(code, signal);
      },
      finish: (tail, code) => {
        processEnded = true;
        unread.tail.push(...tail);
        unread.code = code;
        readOn();
      },
    };
    ptys.push(fake);
    const handle: PtyHandle = {
      pid: 7000 + ptys.length,
      onOutput: (listener) => { outputListeners.push(listener); },
      onExit: (listener) => { exitListeners.push(listener); },
      write: (bytes) => { fake.received.push(bytes); },
      resize: (next) => { fake.size = { ...next }; },
      pause: () => { fake.paused = true; },
      resume: () => { fake.paused = false; readOn(); },
      running: () => !fake.exited && !processEnded,
      groupRunning: () => fake.groupRunning(),
      signal: async (name) => {
        if (fake.slowProcessTable) await tick();
        if (!fake.groupRunning()) { fake.someoneElsesProcessRunning = false; return; }
        if (name === 'SIGKILL' || fake.childEndsOnHangUp) fake.childEnded = true;
        if (name === 'SIGHUP' && fake.ignoresHangUp) return;
        if (fake.exitToldLate) { void tick().then(() => fake.exit(null, name)); return; }
        fake.exit(null, name);
      },
      close: () => { fake.closed = true; },
    };
    return { ok: true, pty: handle };
  };
  return { spawner, ptys };
}
