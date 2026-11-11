import path from 'node:path';
import { unlistedFolder } from './actionPlan.ts';
import type { PaneRun, PaneSize } from './paneProtocol.ts';
import { DEFAULT_PANE_COLUMNS, DEFAULT_PANE_ROWS, MAX_PANE_COLUMNS, MAX_PANE_ROWS, MIN_PANE_COLUMNS, MIN_PANE_ROWS, PANE_RUNS } from './paneProtocol.ts';

/** A pane the page asks for: the folder it opens in, what it runs and the terminal's size. */
export type PaneRequest = { folder: string; run: PaneRun; size: PaneSize };
/** What the project's snapshot says about where a pane may open. */
export type PaneFacts = { folders: string[] };
/** The machine the daemon runs on: the owner's shell, the environment every pane gets, and the disk. */
export type PaneHost = { shell: string; environment: Record<string, string>; isFolder(folder: string): boolean };
/** The process a pane's pty runs: an argv, never a shell line. */
export type PaneLaunch = { command: string; args: string[]; cwd: string };

type Refusal = { ok: false; error: string };
type SizeBound = { key: 'cols' | 'rows'; fallback: number; min: number; max: number };

const COLUMNS: SizeBound = { key: 'cols', fallback: DEFAULT_PANE_COLUMNS, min: MIN_PANE_COLUMNS, max: MAX_PANE_COLUMNS };
const ROWS: SizeBound = { key: 'rows', fallback: DEFAULT_PANE_ROWS, min: MIN_PANE_ROWS, max: MAX_PANE_ROWS };
const WHOLE_NUMBER = /^[0-9]+$/;
/** A login shell, because the environment launchd hands the daemon is thin. */
const LOGIN_SHELL = '-l';
/** The daemon's variables a pane inherits; nothing else, so no token reaches a pane. */
const INHERITED_VARIABLES = ['PATH', 'HOME', 'USER', 'LOGNAME', 'SHELL', 'TMPDIR', 'LANG', 'LC_ALL', 'SSH_AUTH_SOCK'];
const DEFAULT_LANGUAGE = 'en_US.UTF-8';
const TERMINAL_VARIABLES = { TERM: 'xterm-256color', COLORTERM: 'truecolor' };

const refuse = (error: string): Refusal => ({ ok: false, error });
const runNotOpen = (run: PaneRun): string => `a pane runs only a shell for now, not ${run}`;
const sizeRefusal = (bound: SizeBound): string => `${bound.key} must be a whole number from ${bound.min} to ${bound.max}`;

/** Reads a pane's request from its query: `path`, `run`, and `cols` and `rows` (80 by 24 when absent). */
export function parsePaneRequest(query: URLSearchParams): { ok: true; request: PaneRequest } | Refusal {
  const folder = query.get('path') ?? '';
  if (folder === '') return refuse('a pane needs a path');
  const asked = query.get('run');
  const run = PANE_RUNS.find((known) => known === asked) ?? null;
  if (run === null) return refuse(`run must be one of ${PANE_RUNS.join(', ')}`);
  if (run !== 'shell') return refuse(runNotOpen(run));
  const columns = sizeValue(query, COLUMNS);
  if (columns === null) return refuse(sizeRefusal(COLUMNS));
  const rows = sizeValue(query, ROWS);
  if (rows === null) return refuse(sizeRefusal(ROWS));
  return { ok: true, request: { folder, run, size: { cols: columns, rows } } };
}

/** The launch for a pane, or why the daemon refuses it: only in a folder the snapshot lists and the disk holds. */
export function planPane(request: PaneRequest, facts: PaneFacts, host: PaneHost): { ok: true; launch: PaneLaunch } | Refusal {
  if (!path.isAbsolute(request.folder)) return refuse('a pane needs an absolute path');
  const folder = path.resolve(request.folder);
  if (!facts.folders.includes(folder)) return refuse(unlistedFolder(folder));
  if (!host.isFolder(folder)) return refuse(`${folder} is not a folder on this machine`);
  if (request.run !== 'shell') return refuse(runNotOpen(request.run));
  return { ok: true, launch: { command: host.shell, args: [LOGIN_SHELL], cwd: folder } };
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
  return value >= bound.min && value <= bound.max ? value : null;
}
