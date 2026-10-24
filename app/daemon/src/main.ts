import { childProcessRunner } from './collectors/exec.ts';
import { readConfig } from './config.ts';
import { stderrLogger } from './log.ts';
import { DEFAULT_CADENCE, ProjectMonitor } from './project.ts';
import { createConsoleServer } from './server.ts';

const EXIT_BAD_CONFIG = 2;
const clock = (): Date => new Date();
const log = stderrLogger(clock);

const configuration = readConfig(process.argv.slice(2), process.env);
if (!configuration.ok) {
  process.stderr.write(`brain-console: ${configuration.error}\n`);
  process.exit(EXIT_BAD_CONFIG);
}
const { config } = configuration;

const monitors = config.projects.map((project) => new ProjectMonitor({ project, runner: childProcessRunner, clock, log, cadence: DEFAULT_CADENCE }));
const server = createConsoleServer(monitors, { host: config.host, port: config.port, token: config.token, log });

for (const monitor of monitors) {
  monitor.onChange((snapshot) => log.info('snapshot', { project: monitor.project.id, needsYou: snapshot.counts.needsYou, running: snapshot.counts.running, stale: snapshot.counts.stale, free: snapshot.counts.free, disagreements: snapshot.counts.disagreements }));
}

server.listen(config.port, config.host, () => {
  log.info('listening', { url: `http://${config.host}:${config.port}`, projects: config.projects.map((project) => project.id).join(','), token: config.token !== null });
});
await Promise.all(monitors.map((monitor) => monitor.start()));

const shutdown = (): void => {
  for (const monitor of monitors) monitor.stop();
  server.close(() => process.exit(0));
};
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
