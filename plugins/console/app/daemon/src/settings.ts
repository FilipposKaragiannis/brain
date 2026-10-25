import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { DaemonConfig } from './config.ts';
import type { ProjectDefinition } from './project.ts';
import type { SettingOrigin, SettingsView, TerminalName, TerminalSetting } from './snapshot.ts';
import { TERMINAL_NAMES } from './terminal.ts';

export type { SettingOrigin, SettingsView, TerminalSetting };

/** `~/.config/brain-console/config.json`: every field optional. */
export type ConfigFile = { projects?: { root: string }[]; terminal?: TerminalSetting; port?: number };

export type ConfigPaths = {
  /** The settings file the daemon reads and `PUT /api/settings` writes. */
  configFile: string;
  /** The file projects were kept in before config.json; read only while config.json is absent. */
  legacyProjectsFile: string;
};

const CONFIG_DIR = path.join(os.homedir(), '.config', 'brain-console');
export const DEFAULT_CONFIG_PATHS: ConfigPaths = { configFile: path.join(CONFIG_DIR, 'config.json'), legacyProjectsFile: path.join(CONFIG_DIR, 'projects.json') };

const MAX_PORT = 65535;
const FILE_KEYS = ['projects', 'terminal', 'port'];

export type Checked<T> = { ok: true; value: T } | { ok: false; error: string };

const fail = <T>(error: string): Checked<T> => ({ ok: false, error });

export function isTerminalName(value: unknown): value is TerminalName {
  return typeof value === 'string' && (TERMINAL_NAMES as string[]).includes(value);
}

export function checkTerminal(value: unknown): Checked<TerminalSetting> {
  if (isTerminalName(value)) return { ok: true, value };
  if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
    const command = (value as { command?: unknown }).command;
    const keys = Object.keys(value);
    if (keys.length === 1 && Array.isArray(command) && command.length > 0 && command.every((word) => typeof word === 'string' && word !== '')) {
      return { ok: true, value: { command: command as string[] } };
    }
  }
  return fail(`terminal must be one of ${TERMINAL_NAMES.join(', ')} or {"command": [...]} with no empty word`);
}

function checkPort(value: unknown): Checked<number> {
  return typeof value === 'number' && Number.isInteger(value) && value > 0 && value <= MAX_PORT ? { ok: true, value } : fail(`port must be a whole number from 1 to ${MAX_PORT}`);
}

/** A root as the owner typed it: `~/` is the home folder, and anything else must be absolute. */
function checkRoot(value: unknown): Checked<string> {
  if (typeof value !== 'string' || value.trim() === '') return fail('a project root must be a non-empty path');
  const expanded = value.startsWith('~/') ? path.join(os.homedir(), value.slice(2)) : value;
  if (!path.isAbsolute(expanded)) return fail(`a project root must be an absolute path: ${value}`);
  return { ok: true, value: path.resolve(expanded) };
}

/** The shape of the config file, without asking the disk whether the roots hold a flow. */
export function checkConfigFile(value: unknown): Checked<ConfigFile> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return fail('the settings must be a JSON object');
  const record = value as Record<string, unknown>;
  const stray = Object.keys(record).find((key) => !FILE_KEYS.includes(key));
  if (stray !== undefined) return fail(`unknown setting: ${stray}`);
  const file: ConfigFile = {};
  if (record['projects'] !== undefined) {
    if (!Array.isArray(record['projects'])) return fail('projects must be a list of {"root": "..."}');
    const roots: { root: string }[] = [];
    for (const entry of record['projects'] as unknown[]) {
      const root = checkRoot(typeof entry === 'object' && entry !== null ? (entry as { root?: unknown }).root : undefined);
      if (!root.ok) return root;
      roots.push({ root: root.value });
    }
    file.projects = roots;
  }
  if (record['terminal'] !== undefined) {
    const terminal = checkTerminal(record['terminal']);
    if (!terminal.ok) return terminal;
    file.terminal = terminal.value;
  }
  if (record['port'] !== undefined) {
    const port = checkPort(record['port']);
    if (!port.ok) return port;
    file.port = port.value;
  }
  return { ok: true, value: file };
}

/**
 * The projects for a list of roots: each must hold a .flow/config.yaml and no two may share an
 * id (the folder name), or the whole list is refused.
 */
export function projectsFromRoots(roots: string[]): Checked<ProjectDefinition[]> {
  const projects = roots.map((root) => {
    const resolved = path.resolve(root);
    return { id: path.basename(resolved), name: path.basename(resolved), root: resolved };
  });
  const missing = projects.find((project) => !existsSync(path.join(project.root, '.flow', 'config.yaml')));
  if (missing !== undefined) return fail(`${missing.root} has no .flow/config.yaml; run flow:init there first`);
  const duplicate = projects.find((project, index) => projects.findIndex((other) => other.id === project.id) !== index);
  if (duplicate !== undefined) return fail(`two projects share the id ${duplicate.id}`);
  return { ok: true, value: projects };
}

/** What the files on disk say: config.json when it exists, else the projects of the old projects.json. */
export type StoredSettings = { file: ConfigFile; legacy: boolean };

export function readStoredSettings(paths: ConfigPaths): Checked<StoredSettings> {
  if (existsSync(paths.configFile)) {
    const parsed = parseJsonFile(paths.configFile);
    if (!parsed.ok) return parsed;
    const file = checkConfigFile(parsed.value);
    return file.ok ? { ok: true, value: { file: file.value, legacy: false } } : fail(`${paths.configFile}: ${file.error}`);
  }
  if (!existsSync(paths.legacyProjectsFile)) return { ok: true, value: { file: {}, legacy: false } };
  const parsed = parseJsonFile(paths.legacyProjectsFile);
  if (!parsed.ok) return parsed;
  const entries = (parsed.value as { projects?: { root?: unknown }[] } | null)?.projects ?? [];
  const projects = entries.flatMap((entry) => (typeof entry?.root === 'string' ? [{ root: entry.root }] : []));
  return { ok: true, value: { file: { projects }, legacy: true } };
}

function parseJsonFile(file: string): Checked<unknown> {
  try { return { ok: true, value: JSON.parse(readFileSync(file, 'utf8')) as unknown }; } catch (error) {
    return fail(`${file} is not valid JSON: ${error instanceof Error ? error.message : String(error)}`);
  }
}

/** Writes the whole file at once: a reader never sees half of it. */
export function writeConfigFile(file: string, settings: ConfigFile): void {
  mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.${process.pid}.tmp`;
  writeFileSync(temporary, JSON.stringify(settings, null, 2) + '\n');
  renameSync(temporary, file);
}

export type SettingsStoreDependencies = {
  config: DaemonConfig;
  /** The terminals installed now, first choice first; asked on every read, so a new install counts. */
  installed: () => TerminalName[];
  /** Starts and stops monitors so the daemon watches exactly these projects. */
  applyProjects: (projects: ProjectDefinition[]) => void;
};

const PROJECT_NOTES: Record<SettingOrigin, string | null> = {
  flag: 'Set by --project when the daemon started; start it without the flag to edit them here.',
  environment: 'Set by BRAIN_CONSOLE_PROJECTS when the daemon started; start it without that variable to edit them here.',
  file: null,
  default: null,
};

/**
 * The daemon's settings while it runs: what `GET /api/settings` shows and what `PUT` changes.
 * A PUT is checked whole, merged into the file as it is on disk then (a hand edit since the start
 * is kept; a file that no longer parses is refused, never overwritten), written and applied: a new project list at
 * once (when the projects come from the file), the terminal on the next Open in Terminal, the
 * port only after a restart.
 */
export class SettingsStore {
  private readonly deps: SettingsStoreDependencies;
  private file: ConfigFile;
  private legacy: boolean;
  private roots: string[];
  private projectsFrom: SettingOrigin;

  constructor(dependencies: SettingsStoreDependencies) {
    this.deps = dependencies;
    const { config } = dependencies;
    this.file = { ...config.stored.file };
    this.legacy = config.stored.legacy;
    this.roots = config.projects.map((project) => project.root);
    this.projectsFrom = config.origins.projects;
  }

  /** The terminal the owner chose, or null to take the first installed one. */
  terminal(): TerminalSetting | null { return this.file.terminal ?? null; }

  view(): SettingsView {
    const { config } = this.deps;
    return {
      configFile: config.paths.configFile,
      readFromLegacyFile: this.legacy ? config.paths.legacyProjectsFile : null,
      stateDir: config.stateDir,
      launchd: config.launchd,
      projects: { roots: [...this.roots], from: this.projectsFrom, editable: this.projectsFrom === 'file', note: PROJECT_NOTES[this.projectsFrom] },
      terminal: { value: this.terminal(), from: this.file.terminal === undefined ? 'default' : 'file', installed: this.deps.installed() },
      port: {
        value: config.port, from: config.origins.port, saved: this.file.port ?? null,
        note: config.origins.port === 'flag'
          ? `The daemon listens on ${config.port}, set by --port: a port saved here is used only when it starts without --port.`
          : `The daemon listens on ${config.port}; a new port takes a restart of the daemon.`,
      },
    };
  }

  /**
   * Changes the settings a body names and keeps the rest. `terminal: null` goes back to the
   * first installed terminal. Projects set by a flag or the environment cannot change here.
   */
  update(body: unknown): Checked<SettingsView> {
    const clearTerminal = typeof body === 'object' && body !== null && (body as Record<string, unknown>)['terminal'] === null;
    const input = clearTerminal ? Object.fromEntries(Object.entries(body as Record<string, unknown>).filter(([key]) => key !== 'terminal')) : body;
    const checked = checkConfigFile(input);
    if (!checked.ok) return checked;
    const change = checked.value;
    let projects: ProjectDefinition[] | null = null;
    if (change.projects !== undefined) {
      if (this.projectsFrom !== 'file') return fail(`projects cannot change here: ${PROJECT_NOTES[this.projectsFrom] ?? ''}`);
      if (change.projects.length === 0) return fail('keep at least one project: the daemon watches one or more');
      const found = projectsFromRoots(change.projects.map((entry) => entry.root));
      if (!found.ok) return found;
      projects = found.value;
    }
    // The file as it is now, not as it was at start: an edit made by hand since then is kept.
    const onDisk = readStoredSettings(this.deps.config.paths);
    if (!onDisk.ok) return fail(`not saved, so the file is not overwritten: ${onDisk.error}`);
    const next: ConfigFile = { ...onDisk.value.file, ...change };
    if (clearTerminal) delete next.terminal;
    try { writeConfigFile(this.deps.config.paths.configFile, next); } catch (error) {
      return fail(`could not write ${this.deps.config.paths.configFile}: ${error instanceof Error ? error.message : String(error)}`);
    }
    this.file = next;
    this.legacy = false;
    if (projects !== null) {
      this.roots = projects.map((project) => project.root);
      this.deps.applyProjects(projects);
    }
    return { ok: true, value: this.view() };
  }
}
