import { existsSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { ActionRunner, childProcessSpawner, realScheduler } from './actions.ts';
import { newestCachedPlugin } from './cli.ts';
import { childProcessRunner } from './collectors/exec.ts';
import { diskSessionFiles, SessionLocator } from './collectors/sessions.ts';
import { privateFolder, readConfig, startReport } from './config.ts';
import { absoluteFlags, startFailure } from './launchd.ts';
import { stderrLogger } from './log.ts';
import { removePidFile, writePidFile } from './pidFile.ts';
import { DEFAULT_CADENCE, ProjectMonitor } from './project.ts';
import type { ProjectDefinition } from './project.ts';
import { FlowConfigEditor } from './plugins/flow/configEditor.ts';
import { ProjectRegistry } from './registry.ts';
import { fileStamp, listDirs, SelfCheck } from './selfCheck.ts';
import { closeConsoleServer, createConsoleServer } from './server.ts';
import { SettingsStore } from './settings.ts';
import type { SourceName } from './snapshot.ts';
import { SOURCE_NAMES } from './snapshot.ts';
import { installedTerminals } from './terminal.ts';

const EXIT_BAD_CONFIG = 2;
/** How long a stop may take before the process ends anyway, streams or not. */
const SHUTDOWN_GRACE_MS = 3000;

/**
 * `brain-console start [flags]`: the daemon in this process, until SIGINT or SIGTERM. A daemon
 * not started by launchd writes <state dir>/daemon.pid once it listens, so `stop` and `status`
 * find it, and removes it when it stops. A bad config or a port in use ends the process with 2.
 * Once a minute it looks for a newer console in the plugin cache than `version`, the one it
 * runs, and takes a hand edit of the config file.
 */
export async function runDaemon(argv: string[], env: NodeJS.ProcessEnv, version: string): Promise<void> {
  const clock = (): Date => new Date();
  const log = stderrLogger(clock);
  const configuration = readConfig(argv, env);
  if (!configuration.ok) {
    process.stderr.write(startFailure(configuration.error, env));
    process.exit(EXIT_BAD_CONFIG);
  }
  const { config } = configuration;
  const installed = () => installedTerminals(existsSync, os.homedir());
  /** One locator for every project: it caches what it read of the Codex session files. */
  const sessions = new SessionLocator({ home: os.homedir(), clock, files: diskSessionFiles });

  /** A project's monitor and runner. The runner reads the terminal setting at request time, so a change in Settings counts at once. */
  const serve = (project: ProjectDefinition) => {
    const monitor = new ProjectMonitor({ project, runner: childProcessRunner, clock, log, cadence: DEFAULT_CADENCE, sessions, newerConsole: () => selfCheck.newerConsole() });
    const flowConfig = new FlowConfigEditor({ projectId: project.id, root: project.root, runner: childProcessRunner, refresh: async () => { await Promise.all([monitor.refresh('files'), monitor.refresh('jobs')]); }, log });
    const actions = new ActionRunner({
      projectId: project.id,
      context: () => ({ ...monitor.actionContext(), terminal: settings.terminal(), installedTerminals: installed(), writeConfig: (key, value) => flowConfig.setKey(key, value) }),
      spawner: childProcessSpawner, scheduler: realScheduler, clock, log, stateDir: config.stateDir,
      onRefresh: (sources) => { for (const source of sources) if ((SOURCE_NAMES as string[]).includes(source)) void monitor.refresh(source as SourceName); },
    });
    monitor.onChange((snapshot) => log.info('snapshot', { project: project.id, needsYou: snapshot.counts.needsYou, running: snapshot.counts.running, stale: snapshot.counts.stale, free: snapshot.counts.free, disagreements: snapshot.counts.disagreements }));
    return { monitor, actions, flowConfig };
  };
  const registry = new ProjectRegistry(serve, log);
  const settings = new SettingsStore({ config, installed, applyProjects: (projects) => { void registry.apply(projects); }, newerConsole: () => selfCheck.newerConsole() });
  const selfCheck = new SelfCheck({
    running: version,
    newestCached: () => newestCachedPlugin(os.homedir(), { listDirs, launchd: { env, files: { exists: existsSync } } })?.version ?? null,
    configStamp: () => fileStamp(config.paths.configFile),
    onConfigChange: () => {
      const reloaded = settings.reload();
      if (reloaded === null) return;
      if (reloaded.ok) log.info('config.reloaded', { config: config.paths.configFile, projects: reloaded.value.join(',') });
      else log.warn('config.refused', { config: config.paths.configFile, error: reloaded.error });
    },
    scheduler: realScheduler,
  });
  /** The UI as `npm run build` in ui/ leaves it. Without it the daemon is API only. */
  const uiDist = path.resolve(import.meta.dirname, '..', '..', 'ui', 'dist');
  const staticDir = existsSync(path.join(uiDist, 'index.html')) ? uiDist : null;
  const server = createConsoleServer(registry, settings, { host: config.host, port: config.port, token: config.token, staticDir, log });

  privateFolder(config.stateDir);
  server.on('error', (error) => {
    process.stderr.write(startFailure(`cannot listen on ${config.host}:${config.port}: ${error.message}`, env));
    process.exit(EXIT_BAD_CONFIG);
  });
  server.listen(config.port, config.host, () => {
    // The log line names the token file, never the token: under launchd the log is a file on disk.
    const report = startReport(config, staticDir ?? `none (run npm run build in ${path.dirname(uiDist)})`, process.stderr.isTTY === true);
    log.info('listening', report.fields);
    if (report.terminal !== null) process.stderr.write(`${report.terminal}\n`);
    if (!config.launchd) writePidFile(config.stateDir, { pid: process.pid, port: config.port, config: config.paths.configFile, argv: absoluteFlags(argv) });
  });
  selfCheck.start();
  await registry.apply(config.projects);

  let stopping = false;
  const shutdown = (signal: string): void => {
    if (stopping) { log.warn('shutdown.forced', { signal }); process.exit(130); }
    stopping = true;
    log.info('shutdown', { signal });
    if (!config.launchd) removePidFile(config.stateDir, process.pid);
    selfCheck.stop();
    registry.stopAll();
    void Promise.all([closeConsoleServer(server), registry.whenIdle()]).then(() => process.exit(0));
    setTimeout(() => process.exit(0), SHUTDOWN_GRACE_MS).unref();
  };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
}
