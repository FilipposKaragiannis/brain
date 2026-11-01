import { readdirSync, statSync } from 'node:fs';
import type { Scheduler } from './actions.ts';
import { compareVersions } from './cli.ts';
import type { NewerConsole } from './snapshot.ts';

/** How often the daemon looks at the plugin cache and at the config file. */
export const SELF_CHECK_MS = 60000;

export type SelfCheckDependencies = {
  /** The console version this daemon runs. */
  running: string;
  /** The newest console version in the plugin cache, or null when it holds none. */
  newestCached: () => string | null;
  /** When the config file last changed, or null when it is absent. */
  configStamp: () => number | null;
  /** The config file changed on disk since the last look. */
  onConfigChange: () => void;
  scheduler: Scheduler;
};

/**
 * What the daemon checks of itself on start and then once a minute: whether the plugin cache
 * holds a newer console than the one running, and whether the config file changed on disk.
 */
export class SelfCheck {
  private readonly deps: SelfCheckDependencies;
  private cached: string | null = null;
  private stamp: number | null = null;
  private timer: object | null = null;

  constructor(dependencies: SelfCheckDependencies) {
    this.deps = dependencies;
  }

  /** The newer console in the cache as of the last look; null while this one is the newest. */
  newerConsole(): NewerConsole | null {
    const { running } = this.deps;
    return this.cached !== null && compareVersions(this.cached, running) > 0 ? { running, cached: this.cached } : null;
  }

  /** Looks at the cache now and takes the config file as loaded, then looks at both every minute until `stop`. */
  start(): void {
    this.cached = this.deps.newestCached();
    this.stamp = this.deps.configStamp();
    this.schedule();
  }

  stop(): void {
    if (this.timer !== null) this.deps.scheduler.cancel(this.timer);
    this.timer = null;
  }

  private schedule(): void {
    this.timer = this.deps.scheduler.after(SELF_CHECK_MS, () => { this.check(); this.schedule(); });
  }

  private check(): void {
    this.cached = this.deps.newestCached();
    const stamp = this.deps.configStamp();
    if (stamp === this.stamp) return;
    this.stamp = stamp;
    this.deps.onConfigChange();
  }
}

/** When a file last changed, in milliseconds, or null when it is absent. */
export function fileStamp(file: string): number | null {
  try { return statSync(file).mtimeMs; } catch { return null; }
}

/** The folders in a folder, by name; empty when it is missing. */
export function listDirs(folder: string): string[] {
  try { return readdirSync(folder, { withFileTypes: true }).filter((entry) => entry.isDirectory()).map((entry) => entry.name); } catch { return []; }
}
