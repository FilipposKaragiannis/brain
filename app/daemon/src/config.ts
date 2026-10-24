import { existsSync, readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { ProjectDefinition } from './project.ts';

export type DaemonConfig = { projects: ProjectDefinition[]; host: string; port: number; token: string | null };

export const DEFAULT_PORT = 7474;
export const LOCALHOST = '127.0.0.1';
const PROJECTS_FILE = path.join(os.homedir(), '.config', 'brain-console', 'projects.json');

export type ConfigResult = { ok: true; config: DaemonConfig } | { ok: false; error: string };

function projectFromRoot(root: string): ProjectDefinition {
  const resolved = path.resolve(root);
  return { id: path.basename(resolved), name: path.basename(resolved), root: resolved };
}

function projectsFromFile(file: string): string[] {
  if (!existsSync(file)) return [];
  const parsed = JSON.parse(readFileSync(file, 'utf8')) as { projects?: { root?: string }[] };
  return (parsed.projects ?? []).flatMap((entry) => (typeof entry.root === 'string' ? [entry.root] : []));
}

/**
 * Projects come from `--project <root>` flags, else `BRAIN_CONSOLE_PROJECTS` (colon separated),
 * else ~/.config/brain-console/projects.json. Every root must hold a .flow/config.yaml: a bad
 * one stops the daemon before it serves anything.
 */
export function readConfig(argv: string[], env: NodeJS.ProcessEnv): ConfigResult {
  const roots: string[] = [];
  let port = DEFAULT_PORT;
  let token = env['BRAIN_CONSOLE_TOKEN'] ?? null;
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    const value = argv[index + 1];
    if (flag === '--project' && value !== undefined) { roots.push(value); index += 1; continue; }
    if (flag === '--port' && value !== undefined) { port = Number(value); index += 1; continue; }
    if (flag === '--token' && value !== undefined) { token = value; index += 1; continue; }
    return { ok: false, error: `unknown argument: ${flag}` };
  }
  if (roots.length === 0) roots.push(...(env['BRAIN_CONSOLE_PROJECTS'] ?? '').split(':').filter((entry) => entry.length > 0));
  if (roots.length === 0) roots.push(...projectsFromFile(PROJECTS_FILE));
  if (roots.length === 0) return { ok: false, error: `no projects: pass --project <root>, set BRAIN_CONSOLE_PROJECTS or write ${PROJECTS_FILE}` };
  if (!Number.isInteger(port) || port <= 0) return { ok: false, error: `bad port: ${port}` };
  const projects = roots.map(projectFromRoot);
  const missing = projects.find((project) => !existsSync(path.join(project.root, '.flow', 'config.yaml')));
  if (missing !== undefined) return { ok: false, error: `${missing.root} has no .flow/config.yaml; run flow:init there first` };
  const duplicate = projects.find((project, index) => projects.findIndex((other) => other.id === project.id) !== index);
  if (duplicate !== undefined) return { ok: false, error: `two projects share the id ${duplicate.id}` };
  return { ok: true, config: { projects, host: LOCALHOST, port, token: token === '' ? null : token } };
}
