import { randomBytes } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { ProjectDefinition } from './project.ts';
import type { ConfigPaths, SettingOrigin, StoredSettings } from './settings.ts';
import { DEFAULT_CONFIG_PATHS, projectsFromRoots, readStoredSettings } from './settings.ts';

export type DaemonConfig = {
  projects: ProjectDefinition[];
  host: string;
  port: number;
  token: string;
  stateDir: string;
  paths: ConfigPaths;
  /** Where the projects and the port came from; only file projects can change while the daemon runs. */
  origins: { projects: SettingOrigin; port: SettingOrigin };
  /** The settings file as read at start (config.json, else the projects of projects.json). */
  stored: StoredSettings;
  /** launchd started the daemon: the plist `install` writes sets BRAIN_CONSOLE_LAUNCHD=1. */
  launchd: boolean;
};

const TOKEN_BYTES = 24;
const TOKEN_FILE_MODE = 0o600;
/** The state dir holds the token, the audit log and the daemon's own log: the owner's alone. */
const PRIVATE_FOLDER_MODE = 0o700;

export const DEFAULT_PORT = 7474;
export const LOCALHOST = '127.0.0.1';
/** The audit log and action output live here, never inside a project. */
export const DEFAULT_STATE_DIR = path.join(os.homedir(), '.local', 'state', 'brain-console');

export type ConfigResult = { ok: true; config: DaemonConfig } | { ok: false; error: string };

/**
 * Projects come from `--project <root>` flags, else `BRAIN_CONSOLE_PROJECTS` (colon separated),
 * else ~/.config/brain-console/config.json (or, while that is absent, the older projects.json).
 * The port is `--port`, else the file's, else 7474. Every root must hold a .flow/config.yaml: a
 * bad one stops the daemon before it serves anything. `--state-dir` (or BRAIN_CONSOLE_STATE)
 * moves the audit log. `--config <file>` reads and writes the settings in that file instead (the
 * old projects.json is then looked for beside it), so a second daemon never touches the owner's
 * ~/.config/brain-console. Every route needs the token: `--token` or BRAIN_CONSOLE_TOKEN, else the
 * one in <state dir>/token, written on the first start (the folder kept 0700).
 */
export function readConfig(argv: string[], env: NodeJS.ProcessEnv, paths: ConfigPaths = DEFAULT_CONFIG_PATHS): ConfigResult {
  const flagRoots: string[] = [];
  let flagPort: number | null = null;
  let token = env['BRAIN_CONSOLE_TOKEN'] ?? '';
  let stateDir = env['BRAIN_CONSOLE_STATE'] ?? DEFAULT_STATE_DIR;
  let configPaths = paths;
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (flag === '--project' && value !== undefined) { flagRoots.push(value); index += 1; continue; }
    if (flag === '--port' && value !== undefined) { flagPort = Number(value); index += 1; continue; }
    if (flag === '--token' && value !== undefined) { token = value; index += 1; continue; }
    if (flag === '--state-dir' && value !== undefined) { stateDir = value; index += 1; continue; }
    if (flag === '--config' && value !== undefined) {
      const file = path.resolve(value);
      configPaths = { configFile: file, legacyProjectsFile: path.join(path.dirname(file), 'projects.json') };
      index += 1;
      continue;
    }
    return { ok: false, error: `unknown argument: ${flag}` };
  }
  const stored = readStoredSettings(configPaths);
  if (!stored.ok) return stored;
  const { file } = stored.value;
  const envRoots = (env['BRAIN_CONSOLE_PROJECTS'] ?? '').split(':').filter((entry) => entry.length > 0);
  const fileRoots = (file.projects ?? []).map((entry) => entry.root);
  const [roots, projectsFrom]: [string[], SettingOrigin] = flagRoots.length > 0 ? [flagRoots, 'flag'] : envRoots.length > 0 ? [envRoots, 'environment'] : [fileRoots, 'file'];
  if (roots.length === 0) return { ok: false, error: `no projects: pass --project <root>, set BRAIN_CONSOLE_PROJECTS or write ${configPaths.configFile}` };
  const [port, portFrom]: [number, SettingOrigin] = flagPort !== null ? [flagPort, 'flag'] : file.port !== undefined ? [file.port, 'file'] : [DEFAULT_PORT, 'default'];
  if (!Number.isInteger(port) || port <= 0) return { ok: false, error: `bad port: ${port}` };
  const projects = projectsFromRoots(roots);
  if (!projects.ok) return projects;
  const resolvedState = path.resolve(stateDir);
  return {
    ok: true,
    config: {
      projects: projects.value, host: LOCALHOST, port, token: token === '' ? storedToken(resolvedState) : token, stateDir: resolvedState,
      paths: configPaths, origins: { projects: projectsFrom, port: portFrom }, stored: stored.value, launchd: env['BRAIN_CONSOLE_LAUNCHD'] === '1',
    },
  };
}

/** The token kept in <state dir>/token, made on the first start so the URL stays the same after. */
function storedToken(stateDir: string): string {
  const file = path.join(stateDir, 'token');
  if (existsSync(file)) {
    const stored = readFileSync(file, 'utf8').trim();
    if (stored !== '') return stored;
  }
  const token = randomBytes(TOKEN_BYTES).toString('base64url');
  privateFolder(stateDir);
  writeFileSync(file, token + '\n', { mode: TOKEN_FILE_MODE });
  return token;
}

/** Makes the folder if it is missing and closes it to everyone but the owner, whatever mode it had. */
export function privateFolder(folder: string): void {
  mkdirSync(folder, { recursive: true, mode: PRIVATE_FOLDER_MODE });
  chmodSync(folder, PRIVATE_FOLDER_MODE);
}

/** The page to open, with the token in it: only ever printed to the owner's terminal, never logged. */
export function consoleUrl(config: DaemonConfig): string {
  return `http://${config.host}:${config.port}/?token=${config.token}`;
}

/**
 * What the daemon says when it listens: the log line (no token, since under launchd the log is a
 * file) and, when stderr is a terminal, the URL with the token for the owner to open.
 */
export function startReport(config: DaemonConfig, ui: string, interactive: boolean): { fields: Record<string, string>; terminal: string | null } {
  return {
    fields: {
      url: `http://${config.host}:${config.port}/`, tokenFile: path.join(config.stateDir, 'token'), projects: config.projects.map((project) => project.id).join(','),
      stateDir: config.stateDir, config: config.paths.configFile, ui,
    },
    terminal: interactive ? `brain-console: open ${consoleUrl(config)}` : null,
  };
}
