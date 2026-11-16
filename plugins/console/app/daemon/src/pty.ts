import { createRequire } from 'node:module';
import { constants } from 'node:os';
import { errorMessage } from './log.ts';
import type { PaneLaunch } from './panePlan.ts';
import type { PaneSize } from './paneProtocol.ts';
import { processAlive } from './processAlive.ts';
import type { PtyHandle, PtySpawner } from './panes.ts';
import { paneGroups, processTable } from './ptyGroups.ts';

/**
 * The prebuilt node-pty. Upstream node-pty 1.1.0 ships its macOS `spawn-helper` without the
 * execute bit, so every spawn there fails; this build ships it executable and prebuilds Linux too.
 */
const PTY_PACKAGE = '@lydell/node-pty';
const NO_SIGNAL = 0;
/** How long the process table may take to list before a signal goes to the groups already known. */
const PROCESS_TABLE_TIMEOUT_MILLISECONDS = 2000;

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
type PtyModule = { spawn(file: string, commandArguments: string[], options: PtyOptions): PtyProcess };

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
    return { ok: false, error: `the terminal addon (${PTY_PACKAGE}) did not load: ${errorMessage(error)}` };
  }
}

function spawnPty(addon: PtyModule, launch: PaneLaunch, size: PaneSize, environment: Record<string, string>): ReturnType<PtySpawner> {
  try {
    const started = addon.spawn(launch.command, launch.commandArguments, { cols: size.columns, rows: size.rows, cwd: launch.workingFolder, env: environment, encoding: null });
    return { ok: true, pty: ptyHandle(started) };
  } catch (error) {
    return { ok: false, error: `${launch.command} did not start in ${launch.workingFolder}: ${errorMessage(error)}` };
  }
}

function ptyHandle(started: PtyProcess): PtyHandle {
  const groups = new Set([started.pid]);
  let signalling: Promise<void> = Promise.resolve();
  return {
    pid: started.pid,
    onOutput: (listener) => { started.onData((bytes) => listener(bytes)); },
    onExit: (listener) => {
      started.onExit(({ exitCode, signal }) => {
        const name = signalName(signal ?? NO_SIGNAL);
        listener(name === null ? exitCode : null, name);
      });
    },
    write: (bytes) => { started.write(Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength)); },
    resize: (size) => { started.resize(size.columns, size.rows); },
    pause: () => { started.pause(); },
    resume: () => { started.resume(); },
    running: () => processAlive(started.pid),
    groupRunning: () => [...groups].some((group) => processAlive(groupLedBy(group))),
    signal: (name) => {
      signalling = signalling.then(() => signalGroups(groups, name, AbortSignal.timeout(PROCESS_TABLE_TIMEOUT_MILLISECONDS)));
    },
    close: () => { started.destroy(); },
  };
}

/**
 * Signals every group the pane holds: the one the pty's child leads and each job group it started.
 * The groups are looked up before the signal, while the shell that started them still runs.
 */
async function signalGroups(groups: Set<number>, name: 'SIGHUP' | 'SIGKILL', cancel: AbortSignal): Promise<void> {
  for (const group of paneGroups(await processTable(cancel), groups)) groups.add(group);
  for (const group of groups) signalGroup(group, name);
}

/** A group already gone is left alone: its id is free for the system to hand out again. */
function signalGroup(group: number, name: 'SIGHUP' | 'SIGKILL'): void {
  if (!processAlive(groupLedBy(group))) return;
  try {
    process.kill(groupLedBy(group), name);
  } catch {
    return;
  }
}

function groupLedBy(leaderPid: number): number {
  return -leaderPid;
}

function signalName(signal: number): string | null {
  if (signal === NO_SIGNAL) return null;
  const known = Object.entries(constants.signals).find(([, number]) => number === signal);
  return known === undefined ? `signal ${signal}` : known[0];
}
