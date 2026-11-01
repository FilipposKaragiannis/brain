import { existsSync, mkdirSync, readFileSync, renameSync, statSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { DaemonConfig } from './config.ts';
import type { ProjectDefinition } from './project.ts';
import type { NewerConsole, ProjectCheck, ProjectFinding, SettingOrigin, SettingsView, TerminalName, TerminalSetting } from './snapshot.ts';
import { commandText, TERMINAL_NAMES } from './terminal.ts';

export type { ProjectCheck, ProjectFinding, SettingOrigin, SettingsView, TerminalSetting };

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
  if (missing !== undefined) return fail(flowMissing(missing.root));
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

const flowMissing = (root: string): string => `${root} has no .flow/config.yaml; run flow:init there first`;

/** True when the folder, or one above it, holds a `.git` (a folder, or the file a git worktree has), as git itself looks. */
export function insideGitCheckout(folder: string): boolean {
  for (let current = folder; ; current = path.dirname(current)) {
    if (existsSync(path.join(current, '.git'))) return true;
    if (path.dirname(current) === current) return false;
  }
}

/**
 * What the disk says of one resolved root, in the order a settings change asks: it is a folder,
 * it holds .flow/config.yaml, it sits in a git checkout. Nothing more is said of a root that is
 * not a folder. `PUT /api/settings` refuses a list on the first finding that fails, in its words.
 */
export function rootFindings(root: string): ProjectFinding[] {
  let folder: boolean | null = null;
  try { folder = statSync(root).isDirectory(); } catch { folder = null; }
  if (folder === null) return [{ check: 'exists', ok: false, text: `${root} does not exist` }];
  if (!folder) return [{ check: 'exists', ok: false, text: `${root} is not a folder` }];
  const hasFlow = existsSync(path.join(root, '.flow', 'config.yaml'));
  return [
    { check: 'exists', ok: true, text: `${root} exists` },
    hasFlow ? { check: 'flow', ok: true, text: 'it holds .flow/config.yaml' } : { check: 'flow', ok: false, text: flowMissing(root) },
    insideGitCheckout(root) ? { check: 'git', ok: true, text: 'it is in a git checkout' } : { check: 'git', ok: false, text: `${root} is not in a git checkout; the flow works on git branches and worktrees` },
  ];
}

/**
 * A new project list, checked as a settings change is: one or more absolute roots, each a folder
 * in a git checkout holding .flow/config.yaml, no two with one id (the folder name).
 */
export function checkProjectList(roots: string[]): Checked<ProjectDefinition[]> {
  const shape = checkConfigFile({ projects: roots.map((root) => ({ root })) });
  if (!shape.ok) return shape;
  if (roots.length === 0) return fail('keep at least one project: the daemon watches one or more');
  const resolved = (shape.value.projects ?? []).map((entry) => entry.root);
  for (const root of resolved) {
    const failed = rootFindings(root).find((finding) => !finding.ok);
    if (failed !== undefined) return fail(failed.text);
  }
  return projectsFromRoots(resolved);
}

/**
 * A folder the owner wants to add, checked before the PUT: each finding of `rootFindings`, then
 * whether it is watched already and whether a watched project has its folder name. `ok` and
 * `error` are `checkProjectList` of the watched roots and this one, the very check the PUT makes,
 * so the two never disagree.
 */
export function checkNewProject(typed: unknown, watched: string[]): ProjectCheck {
  const root = checkRoot(typed);
  if (!root.ok) return { root: typeof typed === 'string' ? typed : '', id: null, ok: false, error: root.error, findings: [{ check: 'path', ok: false, text: root.error }], initCommand: null };
  const resolved = root.value;
  const id = path.basename(resolved);
  const findings: ProjectFinding[] = [{ check: 'path', ok: true, text: `${resolved} is an absolute path` }, ...rootFindings(resolved)];
  if (findings.every((finding) => finding.check !== 'exists' || finding.ok)) {
    const others = watched.map((entry) => path.resolve(entry));
    if (others.includes(resolved)) findings.push({ check: 'watched', ok: false, text: `${resolved} is watched already` });
    else {
      findings.push({ check: 'watched', ok: true, text: 'it is not watched yet' });
      const clash = others.find((other) => path.basename(other) === id);
      findings.push(clash === undefined
        ? { check: 'name', ok: true, text: `no watched project is called ${id}` }
        : { check: 'name', ok: false, text: `the watched project ${clash} is also called ${id}: the console names a project by its folder, so rename one of the two` });
    }
  }
  const put = checkProjectList([...watched, resolved]);
  const lacksFlow = findings.some((finding) => finding.check === 'flow' && !finding.ok);
  return { root: resolved, id, ok: put.ok, error: put.ok ? null : put.error, findings, initCommand: lacksFlow ? `${commandText(['cd', resolved])} && claude /flow:init` : null };
}

/**
 * Merges a checked change into the file as it is on disk now (an edit made by hand since the
 * daemon started is kept; a file that no longer parses is refused, never overwritten) and writes it.
 */
export function saveSettings(paths: ConfigPaths, change: ConfigFile, clearTerminal = false): Checked<ConfigFile> {
  const onDisk = readStoredSettings(paths);
  if (!onDisk.ok) return fail(`not saved, so the file is not overwritten: ${onDisk.error}`);
  const next: ConfigFile = { ...onDisk.value.file, ...change };
  if (clearTerminal) delete next.terminal;
  try { writeConfigFile(paths.configFile, next); } catch (error) {
    return fail(`could not write ${paths.configFile}: ${error instanceof Error ? error.message : String(error)}`);
  }
  return { ok: true, value: next };
}

export type SettingsStoreDependencies = {
  config: DaemonConfig;
  /** The terminals installed now, first choice first; asked on every read, so a new install counts. */
  installed: () => TerminalName[];
  /** Starts and stops monitors so the daemon watches exactly these projects. */
  applyProjects: (projects: ProjectDefinition[]) => void;
  /** A newer console in the plugin cache than the one running, as the daemon last saw it. */
  newerConsole: () => NewerConsole | null;
};

/** Two readings of the file hold the same settings, whatever the order of their keys. */
const sameSettings = (left: ConfigFile, right: ConfigFile): boolean =>
  JSON.stringify([left.projects ?? [], left.terminal ?? null, left.port ?? null]) === JSON.stringify([right.projects ?? [], right.terminal ?? null, right.port ?? null]);

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
  private fileError: string | null = null;

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
      fileError: this.fileError,
      newerConsole: this.deps.newerConsole(),
    };
  }

  /** A folder checked as a PUT that adds it to the watched projects would be, and refused the same way while a flag or the environment sets them. */
  checkProject(root: unknown): ProjectCheck {
    const check = checkNewProject(root, this.roots);
    if (this.projectsFrom === 'file') return check;
    return { ...check, ok: false, error: `projects cannot change here: ${PROJECT_NOTES[this.projectsFrom] ?? ''}` };
  }

  /** The files `POST /api/open` may show: the console's settings file and its state folder. */
  files(): { path: string; folder: boolean }[] {
    return [{ path: this.deps.config.paths.configFile, folder: false }, { path: this.deps.config.stateDir, folder: true }];
  }

  /**
   * Reads the file again after it changed on disk, and takes a hand edit as a PUT would: the
   * projects applied at once when they come from the file (a flag or the environment keeps
   * them fixed), the terminal on the next Open in Terminal. A file that does not parse, or whose
   * projects fail the PUT's checks, is refused: the daemon keeps what it loaded and the view says
   * why until the file is fixed. The roots watched after a reload; null when the file holds what
   * the daemon runs already.
   */
  reload(): Checked<string[]> | null {
    const stored = readStoredSettings(this.deps.config.paths);
    if (!stored.ok) { this.fileError = stored.error; return stored; }
    const { file } = stored.value;
    if (sameSettings(file, this.file)) { this.fileError = null; return null; }
    let projects: ProjectDefinition[] | null = null;
    if (this.projectsFrom === 'file') {
      const found = checkProjectList((file.projects ?? []).map((entry) => entry.root));
      if (!found.ok) { this.fileError = found.error; return found; }
      projects = found.value;
    }
    this.file = file;
    this.legacy = stored.value.legacy;
    this.fileError = null;
    if (projects !== null) {
      this.roots = projects.map((project) => project.root);
      this.deps.applyProjects(projects);
    }
    return { ok: true, value: [...this.roots] };
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
      const found = checkProjectList(change.projects.map((entry) => entry.root));
      if (!found.ok) return found;
      projects = found.value;
    }
    const saved = saveSettings(this.deps.config.paths, change, clearTerminal);
    if (!saved.ok) return saved;
    const next = saved.value;
    this.file = next;
    this.legacy = false;
    if (projects !== null) {
      this.roots = projects.map((project) => project.root);
      this.deps.applyProjects(projects);
    }
    return { ok: true, value: this.view() };
  }
}
