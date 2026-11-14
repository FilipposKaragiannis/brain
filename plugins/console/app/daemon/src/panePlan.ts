import path from 'node:path';
import { unlistedFolder } from './actionPlan.ts';
import type { PaneRun, PaneSize } from './paneProtocol.ts';
import { DEFAULT_PANE_COLUMNS, DEFAULT_PANE_ROWS, MAXIMUM_PANE_COLUMNS, MAXIMUM_PANE_ROWS, MINIMUM_PANE_COLUMNS, MINIMUM_PANE_ROWS, PANE_RUNS } from './paneProtocol.ts';

/** A pane the page asks for: the folder it opens in, what it runs and the terminal's size. */
export type PaneRequest = { folder: string; run: PaneRun; size: PaneSize };
/** What the project says about a pane: the folders it may open in. */
export type PaneFacts = { folders: string[] };
/** The machine the daemon runs on: the owner's shell, the environment every pane gets, and the disk. */
export type PaneHost = { shell: string; environment: Record<string, string>; isFolder(folder: string): boolean };
/** The process a pane's pty runs: an argv, never a shell line, and the folder it starts in. */
export type PaneLaunch = { command: string; commandArguments: string[]; workingFolder: string };

type Refusal = { ok: false; error: string };
type SizeBound = { key: 'cols' | 'rows'; fallback: number; minimum: number; maximum: number };
type Planned = { ok: true; launch: PaneLaunch } | Refusal;

const COLUMNS: SizeBound = { key: 'cols', fallback: DEFAULT_PANE_COLUMNS, minimum: MINIMUM_PANE_COLUMNS, maximum: MAXIMUM_PANE_COLUMNS };
const ROWS: SizeBound = { key: 'rows', fallback: DEFAULT_PANE_ROWS, minimum: MINIMUM_PANE_ROWS, maximum: MAXIMUM_PANE_ROWS };
const WHOLE_NUMBER = /^[0-9]+$/;
/** A login shell, because the environment launchd hands the daemon is thin. */
const LOGIN_SHELL = '-l';
/** The daemon's variables a pane inherits; nothing else, so no token reaches a pane. */
const INHERITED_VARIABLES = ['PATH', 'HOME', 'USER', 'LOGNAME', 'SHELL', 'TMPDIR', 'LANG', 'LC_ALL', 'SSH_AUTH_SOCK'];
const DEFAULT_LANGUAGE = 'en_US.UTF-8';
const TERMINAL_VARIABLES = { TERM: 'xterm-256color', COLORTERM: 'truecolor' };

const refuse = (error: string): Refusal => ({ ok: false, error });
const sizeRefusal = (bound: SizeBound): string => `${bound.key} must be a whole number from ${bound.minimum} to ${bound.maximum}`;

/** Reads a pane's request from its query: `path`, `run`, and `cols` and `rows` (80 by 24 when absent). */
export function parsePaneRequest(query: URLSearchParams): { ok: true; request: PaneRequest } | Refusal {
  const folder = query.get('path') ?? '';
  if (folder === '') return refuse('a pane needs a path');
  const asked = query.get('run');
  const run = PANE_RUNS.find((known) => known === asked) ?? null;
  if (run === null) return refuse(`run must be one of ${PANE_RUNS.join(', ')}`);
  const columns = sizeValue(query, COLUMNS);
  if (columns === null) return refuse(sizeRefusal(COLUMNS));
  const rows = sizeValue(query, ROWS);
  if (rows === null) return refuse(sizeRefusal(ROWS));
  return { ok: true, request: { folder, run, size: { columns, rows } } };
}

/**
 * The launch for a pane, or why the daemon refuses it: the owner's login shell, only in a folder
 * the snapshot lists and the disk holds.
 */
export function planPane(request: PaneRequest, facts: PaneFacts, host: PaneHost): Planned {
  const checked = listedFolder(request.folder, facts, host);
  if (!checked.ok) return checked;
  return { ok: true, launch: { command: host.shell, commandArguments: [LOGIN_SHELL], workingFolder: checked.folder } };
}

function listedFolder(asked: string, facts: PaneFacts, host: PaneHost): { ok: true; folder: string } | Refusal {
  if (!path.isAbsolute(asked)) return refuse('a pane needs an absolute path');
  const folder = path.resolve(asked);
  if (!facts.folders.includes(folder)) return refuse(unlistedFolder(folder));
  if (!host.isFolder(folder)) return refuse(`${folder} is not a folder on this machine`);
  return { ok: true, folder };
}

/** The environment every pane gets: the allow-listed variables of the daemon's, a language, and a terminal that draws colour. */
export function paneEnvironment(environment: Readonly<Record<string, string | undefined>>): Record<string, string> {
  const inherited: Record<string, string> = { LANG: DEFAULT_LANGUAGE };
  for (const name of INHERITED_VARIABLES) {
    const value = environment[name];
    if (value !== undefined && value !== '') inherited[name] = value;
  }
  return { ...inherited, ...TERMINAL_VARIABLES };
}

function sizeValue(query: URLSearchParams, bound: SizeBound): number | null {
  const text = query.get(bound.key);
  if (text === null) return bound.fallback;
  if (!WHOLE_NUMBER.test(text)) return null;
  const value = Number(text);
  return value >= bound.minimum && value <= bound.maximum ? value : null;
}
