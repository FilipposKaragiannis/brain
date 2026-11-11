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
  /** The signals the process group got, in order. */
  signals: string[];
  /** Whether the master is closed. */
  closed: boolean;
  /** Whether the process has ended. */
  exited: boolean;
  /** When true the process ignores SIGHUP, as `nohup` does, and only SIGKILL ends it. */
  ignoresHangUp: boolean;
  /** How many times the daemon asked whether the process still runs, as a pid probe would. */
  exitProbes: number;
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
      launch, environment, size: { ...size }, received: [], paused: false, signals: [], closed: false, exited: false, ignoresHangUp: false, exitProbes: 0,
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
      running: () => {
        fake.exitProbes += 1;
        return !fake.exited && !processEnded;
      },
      signal: (name) => {
        fake.signals.push(name);
        if (name === 'SIGHUP' && fake.ignoresHangUp) return;
        fake.exit(null, name);
      },
      close: () => { fake.closed = true; },
    };
    return { ok: true, pty: handle };
  };
  return { spawner, ptys };
}
