import { createRequire } from 'node:module';
import { constants } from 'node:os';
import type { PaneLaunch } from './panePlan.ts';
import type { PaneSize } from './paneProtocol.ts';
import type { PtyHandle, PtySpawner } from './panes.ts';

/**
 * The prebuilt node-pty. Upstream node-pty 1.1.0 ships its macOS `spawn-helper` without the
 * execute bit, so every spawn there fails; this build ships it executable and prebuilds Linux too.
 */
const PTY_PACKAGE = '@lydell/node-pty';
const NO_SIGNAL = 0;

/**
 * The part of the addon's module a pane uses, with output as bytes (`encoding: null`). `destroy`
 * is the terminal's own: it closes the master. The package's typings leave it out, so the module
 * is described here rather than imported.
 */
type PtyProcess = {
  readonly pid: number;
  onData(listener: (bytes: Buffer) => void): unknown;
  onExit(listener: (ended: { exitCode: number; signal?: number }) => void): unknown;
  write(bytes: Buffer): void;
  resize(columns: number, rows: number): void;
  pause(): void;
  resume(): void;
  destroy(): void;
};
/** node-pty's own option names; `spawnPty` is where a pane's names become them. */
type PtyOptions = { cols: number; rows: number; cwd: string; env: Record<string, string>; encoding: null };
type PtyModule = { spawn(file: string, args: string[], options: PtyOptions): PtyProcess };

const failure = (error: unknown): string => (error instanceof Error ? error.message : String(error));

/**
 * The real `PtySpawner`. The addon loads on the first spawn, so a daemon whose addon cannot load
 * still starts; a load or spawn that fails is a refusal with the reason, never a throw.
 */
export function ptySpawner(): PtySpawner {
  let loaded: PtyModule | null = null;
  return (launch, size, environment) => {
    if (loaded === null) {
      const load = loadPty();
      if (!load.ok) return load;
      loaded = load.addon;
    }
    return spawnPty(loaded, launch, size, environment);
  };
}

function loadPty(): { ok: true; addon: PtyModule } | { ok: false; error: string } {
  try {
    const addon: PtyModule = createRequire(import.meta.url)(PTY_PACKAGE);
    return { ok: true, addon };
  } catch (error) {
    return { ok: false, error: `the terminal addon (${PTY_PACKAGE}) did not load: ${failure(error)}` };
  }
}

function spawnPty(addon: PtyModule, launch: PaneLaunch, size: PaneSize, environment: Record<string, string>): ReturnType<PtySpawner> {
  try {
    const started = addon.spawn(launch.command, launch.args, { cols: size.columns, rows: size.rows, cwd: launch.workingFolder, env: environment, encoding: null });
    return { ok: true, pty: ptyHandle(started) };
  } catch (error) {
    return { ok: false, error: `${launch.command} did not start in ${launch.workingFolder}: ${failure(error)}` };
  }
}

function ptyHandle(started: PtyProcess): PtyHandle {
  return {
    pid: started.pid,
    onOutput: (listener) => { started.onData((bytes) => listener(bytes)); },
    onExit: (listener) => {
      started.onExit(({ exitCode, signal }) => {
        const name = signalName(signal ?? NO_SIGNAL);
        listener(name === null ? exitCode : null, name);
      });
    },
    write: (bytes) => { started.write(Buffer.from(bytes)); },
    resize: (size) => { started.resize(size.columns, size.rows); },
    pause: () => { started.pause(); },
    resume: () => { started.resume(); },
    signal: (name) => { signalGroup(started.pid, name); },
    close: () => { started.destroy(); },
  };
}

/** Signals the group the pty's child leads (it leads its own session); a group already gone is left alone. */
function signalGroup(pid: number, name: 'SIGHUP' | 'SIGKILL'): void {
  try {
    process.kill(-pid, name);
  } catch {
    return;
  }
}

function signalName(signal: number): string | null {
  if (signal === NO_SIGNAL) return null;
  const known = Object.entries(constants.signals).find(([, number]) => number === signal);
  return known === undefined ? `signal ${signal}` : known[0];
}
