import { existsSync } from 'node:fs';
import path from 'node:path';
import { ActionRunner, childProcessSpawner, realScheduler } from './actions.ts';
import { childProcessRunner } from './collectors/exec.ts';
import { readConfig } from './config.ts';
import { stderrLogger } from './log.ts';
import { DEFAULT_CADENCE, ProjectMonitor } from './project.ts';
import { createConsoleServer } from './server.ts';
import type { ServedProject } from './server.ts';
import type { SourceName } from './snapshot.ts';
import { SOURCE_NAMES } from './snapshot.ts';

const EXIT_BAD_CONFIG = 2;
const clock = (): Date => new Date();
const log = stderrLogger(clock);

const configuration = readConfig(process.argv.slice(2), process.env);
if (!configuration.ok) {
  process.stderr.write(`brain-console: ${configuration.error}\n`);
  process.exit(EXIT_BAD_CONFIG);
}
const { config } = configuration;

const served: ServedProject[] = config.projects.map((project) => {
  const monitor = new ProjectMonitor({ project, runner: childProcessRunner, clock, log, cadence: DEFAULT_CADENCE });
  const actions = new ActionRunner({
    projectId: project.id, context: () => monitor.actionContext(), spawner: childProcessSpawner, scheduler: realScheduler, clock, log, stateDir: config.stateDir,
    onRefresh: (sources) => { for (const source of sources) if ((SOURCE_NAMES as string[]).includes(source)) void monitor.refresh(source as SourceName); },
  });
  return { monitor, actions };
});
const monitors = served.map((entry) => entry.monitor);
/** The UI as `npm run build` in app/ui leaves it. Without it the daemon is API only. */
const uiDist = path.resolve(import.meta.dirname, '..', '..', 'ui', 'dist');
const staticDir = existsSync(path.join(uiDist, 'index.html')) ? uiDist : null;
const server = createConsoleServer(served, { host: config.host, port: config.port, token: config.token, staticDir, log });

for (const monitor of monitors) {
  monitor.onChange((snapshot) => log.info('snapshot', { project: monitor.project.id, needsYou: snapshot.counts.needsYou, running: snapshot.counts.running, stale: snapshot.counts.stale, free: snapshot.counts.free, disagreements: snapshot.counts.disagreements }));
}

server.listen(config.port, config.host, () => {
  log.info('listening', { url: `http://${config.host}:${config.port}/?token=${config.token}`, projects: config.projects.map((project) => project.id).join(','), stateDir: config.stateDir, ui: staticDir ?? 'none (run npm run build in app/ui)' });
});
await Promise.all(monitors.map((monitor) => monitor.start()));

const shutdown = (): void => {
  for (const { monitor, actions } of served) { actions.stopAll(); monitor.stop(); }
  server.close(() => process.exit(0));
};
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
