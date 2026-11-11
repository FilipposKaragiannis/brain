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
  /** Bytes the process writes to the terminal. */
  emit(bytes: Uint8Array): void;
  /** Ends the process. */
  exit(code: number | null, signal: string | null): void;
};

/** A spawner that forks nothing: each spawn hands the test a pty it drives by hand, or the refusal it was given. */
export function fakePty(refusal: string | null): { spawner: PtySpawner; ptys: FakePty[] } {
  const ptys: FakePty[] = [];
  const spawner: PtySpawner = (launch, size, environment) => {
    if (refusal !== null) return { ok: false, error: refusal };
    const outputListeners: ((bytes: Uint8Array) => void)[] = [];
    const exitListeners: ((code: number | null, signal: string | null) => void)[] = [];
    const fake: FakePty = {
      launch, environment, size: { ...size }, received: [], paused: false, signals: [], closed: false, exited: false, ignoresHangUp: false,
      emit: (bytes) => { for (const listener of outputListeners) listener(bytes); },
      exit: (code, signal) => {
        if (fake.exited) return;
        fake.exited = true;
        for (const listener of exitListeners) listener(code, signal);
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
      resume: () => { fake.paused = false; },
      running: () => !fake.exited,
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
