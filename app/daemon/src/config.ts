import { randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
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
 * moves the audit log. Every route needs the token: `--token` or BRAIN_CONSOLE_TOKEN, else the
 * one in <state dir>/token, written on the first start and printed with the URL.
 */
export function readConfig(argv: string[], env: NodeJS.ProcessEnv, paths: ConfigPaths = DEFAULT_CONFIG_PATHS): ConfigResult {
  const flagRoots: string[] = [];
  let flagPort: number | null = null;
  let token = env['BRAIN_CONSOLE_TOKEN'] ?? '';
  let stateDir = env['BRAIN_CONSOLE_STATE'] ?? DEFAULT_STATE_DIR;
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (flag === '--project' && value !== undefined) { flagRoots.push(value); index += 1; continue; }
    if (flag === '--port' && value !== undefined) { flagPort = Number(value); index += 1; continue; }
    if (flag === '--token' && value !== undefined) { token = value; index += 1; continue; }
    if (flag === '--state-dir' && value !== undefined) { stateDir = value; index += 1; continue; }
    return { ok: false, error: `unknown argument: ${flag}` };
  }
  const stored = readStoredSettings(paths);
  if (!stored.ok) return stored;
  const { file } = stored.value;
  const envRoots = (env['BRAIN_CONSOLE_PROJECTS'] ?? '').split(':').filter((entry) => entry.length > 0);
  const fileRoots = (file.projects ?? []).map((entry) => entry.root);
  const [roots, projectsFrom]: [string[], SettingOrigin] = flagRoots.length > 0 ? [flagRoots, 'flag'] : envRoots.length > 0 ? [envRoots, 'environment'] : [fileRoots, 'file'];
  if (roots.length === 0) return { ok: false, error: `no projects: pass --project <root>, set BRAIN_CONSOLE_PROJECTS or write ${paths.configFile}` };
  const [port, portFrom]: [number, SettingOrigin] = flagPort !== null ? [flagPort, 'flag'] : file.port !== undefined ? [file.port, 'file'] : [DEFAULT_PORT, 'default'];
  if (!Number.isInteger(port) || port <= 0) return { ok: false, error: `bad port: ${port}` };
  const projects = projectsFromRoots(roots);
  if (!projects.ok) return projects;
  const resolvedState = path.resolve(stateDir);
  return {
    ok: true,
    config: {
      projects: projects.value, host: LOCALHOST, port, token: token === '' ? storedToken(resolvedState) : token, stateDir: resolvedState,
      paths, origins: { projects: projectsFrom, port: portFrom }, stored: stored.value, launchd: env['BRAIN_CONSOLE_LAUNCHD'] === '1',
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
  mkdirSync(stateDir, { recursive: true });
  writeFileSync(file, token + '\n', { mode: TOKEN_FILE_MODE });
  return token;
}
