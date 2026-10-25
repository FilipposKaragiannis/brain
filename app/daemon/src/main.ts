import { execFile } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { connect } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { ActionRunner, childProcessSpawner, realScheduler } from './actions.ts';
import { childProcessRunner } from './collectors/exec.ts';
import { readConfig } from './config.ts';
import { install, status, uninstall } from './launchd.ts';
import type { LaunchdDependencies } from './launchd.ts';
import { stderrLogger } from './log.ts';
import { DEFAULT_CADENCE, ProjectMonitor } from './project.ts';
import type { ProjectDefinition } from './project.ts';
import { ProjectRegistry } from './registry.ts';
import { closeConsoleServer, createConsoleServer } from './server.ts';
import { DEFAULT_CONFIG_PATHS, SettingsStore } from './settings.ts';
import type { SourceName } from './snapshot.ts';
import { SOURCE_NAMES } from './snapshot.ts';
import { installedTerminals } from './terminal.ts';

const EXIT_BAD_CONFIG = 2;
const clock = (): Date => new Date();
const log = stderrLogger(clock);

const PORT_POLL_MS = 250;

/** Something accepts connections on the port, tried every quarter second until the time runs out. */
function waitForPort(host: string, port: number, timeoutMs: number): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve) => {
    const attempt = (): void => {
      const socket = connect(port, host);
      socket.once('connect', () => { socket.end(); resolve(true); });
      socket.once('error', () => { socket.destroy(); if (Date.now() > deadline) resolve(false); else setTimeout(attempt, PORT_POLL_MS); });
    };
    attempt();
  });
}

const launchd: LaunchdDependencies = {
  launchctl: (args) => new Promise((resolve) => {
    execFile('launchctl', args, { encoding: 'utf8' }, (error, stdout, stderr) => resolve({ code: error === null ? 0 : typeof error.code === 'number' ? error.code : 1, stdout, stderr }));
  }),
  files: {
    write: (file, text) => writeFileSync(file, text), remove: (file) => rmSync(file, { force: true }), exists: existsSync,
    read: (file) => readFileSync(file, 'utf8'), mkdir: (folder) => { mkdirSync(folder, { recursive: true }); },
  },
  waitForPort, print: (line) => process.stdout.write(`${line}\n`), env: process.env, uid: process.getuid?.() ?? 0, home: os.homedir(),
  node: process.execPath, daemon: path.resolve(import.meta.filename), configPaths: DEFAULT_CONFIG_PATHS,
};

/** `install`, `uninstall` and `status` manage the launchd job and exit; anything else starts the daemon. */
const [subcommand, ...subcommandArgs] = process.argv.slice(2);
if (subcommand === 'install') process.exit(await install(subcommandArgs, launchd));
if (subcommand === 'uninstall') process.exit(await uninstall(launchd));
if (subcommand === 'status') process.exit(await status(launchd));

const configuration = readConfig(process.argv.slice(2), process.env);
if (!configuration.ok) {
  process.stderr.write(`brain-console: ${configuration.error}\n`);
  process.exit(EXIT_BAD_CONFIG);
}
const { config } = configuration;
const installed = () => installedTerminals(existsSync, os.homedir());

/** A project's monitor and runner. The runner reads the terminal setting at request time, so a change in Settings counts at once. */
const serve = (project: ProjectDefinition) => {
  const monitor = new ProjectMonitor({ project, runner: childProcessRunner, clock, log, cadence: DEFAULT_CADENCE });
  const actions = new ActionRunner({
    projectId: project.id, context: () => ({ ...monitor.actionContext(), terminal: settings.terminal(), installedTerminals: installed() }), spawner: childProcessSpawner, scheduler: realScheduler, clock, log, stateDir: config.stateDir,
    onRefresh: (sources) => { for (const source of sources) if ((SOURCE_NAMES as string[]).includes(source)) void monitor.refresh(source as SourceName); },
  });
  monitor.onChange((snapshot) => log.info('snapshot', { project: project.id, needsYou: snapshot.counts.needsYou, running: snapshot.counts.running, stale: snapshot.counts.stale, free: snapshot.counts.free, disagreements: snapshot.counts.disagreements }));
  return { monitor, actions };
};
const registry = new ProjectRegistry(serve, log);
const settings = new SettingsStore({ config, installed, applyProjects: (projects) => { void registry.apply(projects); } });
/** The UI as `npm run build` in app/ui leaves it. Without it the daemon is API only. */
const uiDist = path.resolve(import.meta.dirname, '..', '..', 'ui', 'dist');
const staticDir = existsSync(path.join(uiDist, 'index.html')) ? uiDist : null;
const server = createConsoleServer(registry, settings, { host: config.host, port: config.port, token: config.token, staticDir, log });

server.listen(config.port, config.host, () => {
  log.info('listening', { url: `http://${config.host}:${config.port}/?token=${config.token}`, projects: config.projects.map((project) => project.id).join(','), stateDir: config.stateDir, config: config.paths.configFile, ui: staticDir ?? 'none (run npm run build in app/ui)' });
});
await registry.apply(config.projects);

/** How long a stop may take before the process ends anyway, streams or not. */
const SHUTDOWN_GRACE_MS = 3000;
let stopping = false;
const shutdown = (signal: string): void => {
  if (stopping) { log.warn('shutdown.forced', { signal }); process.exit(130); }
  stopping = true;
  log.info('shutdown', { signal });
  registry.stopAll();
  void closeConsoleServer(server).then(() => process.exit(0));
  setTimeout(() => process.exit(0), SHUTDOWN_GRACE_MS).unref();
};
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
