import { execFile, spawn } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { connect } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { daemonEntry, runCli } from './cli.ts';
import type { CliDependencies } from './cli.ts';
import { DEFAULT_STATE_DIR, privateFolder } from './config.ts';
import { runDaemon } from './daemon.ts';
import type { LaunchdDependencies } from './launchd.ts';
import { DEFAULT_CONFIG_PATHS } from './settings.ts';

/**
 * The `brain-console` command: `node main.ts <subcommand>`. The real world behind `runCli`'s
 * dependencies, each one overridable by the environment where a trial needs it: HOME (the
 * plist, the plugin cache, the default config and state), BRAIN_CONSOLE_HOME (where the console
 * is installed), BRAIN_CONSOLE_STATE (the state dir), BRAIN_CONSOLE_NODE (the node the plist
 * runs) and BRAIN_CONSOLE_LAUNCHCTL (the launchctl it calls). `--config` and `--state-dir` go on
 * the command line.
 */
const env = process.env;
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

/** The process listening on the port, from lsof, as "pid 4242 (node)"; null when none (or no lsof). */
function portHolder(port: number): Promise<string | null> {
  return new Promise((resolve) => {
    execFile('lsof', ['-nP', `-iTCP:${port}`, '-sTCP:LISTEN', '-Fpc'], { encoding: 'utf8' }, (_error, stdout) => {
      const pid = /^p(\d+)$/m.exec(stdout ?? '')?.[1];
      const command = /^c(.+)$/m.exec(stdout ?? '')?.[1];
      resolve(pid === undefined ? null : `pid ${pid}${command === undefined ? '' : ` (${command})`}`);
    });
  });
}

/** A child with this terminal for its input and output; resolves to its exit code. */
function inherit(command: string, args: string[]): Promise<number> {
  return new Promise((resolve) => {
    const child = spawn(command, args, { stdio: 'inherit' });
    child.once('error', () => resolve(127));
    child.once('exit', (code) => resolve(code ?? 1));
  });
}

const realpath = (file: string): string | null => { try { return realpathSync(file); } catch { return null; } };
const home = os.homedir();
const launchctl = env['BRAIN_CONSOLE_LAUNCHCTL'] ?? 'launchctl';

const launchd: LaunchdDependencies = {
  launchctl: (args) => new Promise((resolve) => {
    execFile(launchctl, args, { encoding: 'utf8' }, (error, stdout, stderr) => resolve({ code: error === null ? 0 : typeof error.code === 'number' ? error.code : 1, stdout, stderr }));
  }),
  files: {
    write: (file, text) => writeFileSync(file, text), remove: (file) => rmSync(file, { force: true }), exists: existsSync,
    read: (file) => readFileSync(file, 'utf8'), mkdir: (folder) => { mkdirSync(folder, { recursive: true }); }, privateFolder,
  },
  portHolder,
  waitForPort, print: (line) => process.stdout.write(`${line}\n`), env, uid: process.getuid?.() ?? 0, home,
  node: env['BRAIN_CONSOLE_NODE'] ?? process.execPath,
  daemon: daemonEntry(path.resolve(import.meta.filename), env['BRAIN_CONSOLE_HOME'] ?? home, realpath),
  configPaths: DEFAULT_CONFIG_PATHS,
};

const packageJson = JSON.parse(readFileSync(path.resolve(import.meta.dirname, '..', '..', 'package.json'), 'utf8')) as { version: string };

const deps: CliDependencies = {
  launchd,
  version: packageJson.version,
  defaultStateDir: DEFAULT_STATE_DIR,
  cwd: process.cwd(),
  isAlive: (pid) => { try { process.kill(pid, 0); return true; } catch (error) { return (error as NodeJS.ErrnoException).code === 'EPERM'; } },
  kill: (pid, signal) => { try { process.kill(pid, signal); } catch { /* gone already */ } },
  sleep: (ms) => new Promise((resolve) => { setTimeout(resolve, ms); }),
  http: async (url, method, token, body) => {
    const headers: Record<string, string> = { authorization: `Bearer ${token}` };
    if (body !== undefined) headers['content-type'] = 'application/json';
    const response = await fetch(url, body === undefined ? { method, headers } : { method, headers, body: JSON.stringify(body) });
    const text = await response.text();
    try { return { status: response.status, body: JSON.parse(text) as unknown }; } catch { return { status: response.status, body: text }; }
  },
  openUrl: (url) => inherit('open', [url]),
  tail: (file, follow) => inherit('tail', ['-n', '200', ...(follow ? ['-f'] : []), file]),
  runScript: (file, args) => inherit('sh', [file, ...args]),
  // The daemon keeps this process alive; it exits on its own, so this never resolves.
  startDaemon: async (argv) => { await runDaemon(argv, env); return new Promise<number>(() => {}); },
  listDirs: (folder) => { try { return readdirSync(folder, { withFileTypes: true }).filter((entry) => entry.isDirectory()).map((entry) => entry.name); } catch { return []; } },
};

process.exit(await runCli(process.argv.slice(2), deps));
