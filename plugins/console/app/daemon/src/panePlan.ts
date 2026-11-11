import path from 'node:path';
import { HOST_EFFORTS, MODEL, unlistedFolder } from './actionPlan.ts';
import { codexModel } from './plugins/flow/jobsPair.ts';
import type { JobsPair, JobsPairs } from './plugins/flow/jobsPair.ts';
import type { JobsHost } from './plugins/flow/schema.ts';
import type { PaneRun, PaneSize } from './paneProtocol.ts';
import { DEFAULT_PANE_COLUMNS, DEFAULT_PANE_ROWS, MAXIMUM_PANE_COLUMNS, MAXIMUM_PANE_ROWS, MINIMUM_PANE_COLUMNS, MINIMUM_PANE_ROWS, PANE_RUNS } from './paneProtocol.ts';

/** A pane the page asks for: the folder it opens in, what it runs and the terminal's size. */
export type PaneRequest = { folder: string; run: PaneRun; size: PaneSize };
/** What the project says about a pane: the folders it may open in, and the pair each host's quick session starts with. */
export type PaneFacts = { folders: string[]; pairs: JobsPairs };
/**
 * The machine the daemon runs on: the owner's shell, the environment every pane gets, the disk,
 * and the absolute path of a program on the daemon's PATH (null when none is there).
 */
export type PaneHost = { shell: string; environment: Record<string, string>; isFolder(folder: string): boolean; executable(name: string): string | null };
/** The process a pane's pty runs: an argv, never a shell line, and the folder it starts in. */
export type PaneLaunch = { command: string; commandArguments: string[]; workingFolder: string };

/** A project with no flow config sets no pair: each host starts on its own default model and effort. */
export const NO_JOBS_PAIRS: JobsPairs = { claude: { model: null, effort: null, from: 'jobs.claude' }, codex: { model: null, effort: null, from: 'jobs.codex' } };

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
 * The launch for a pane, or why the daemon refuses it: only in a folder the snapshot lists and the
 * disk holds. A shell is the owner's login shell; a quick session is the agent's absolute path with
 * the project's model and effort, each flag only when the pair sets it, and no permission flag.
 */
export function planPane(request: PaneRequest, facts: PaneFacts, host: PaneHost): Planned {
  const checked = listedFolder(request.folder, facts, host);
  if (!checked.ok) return checked;
  if (request.run === 'shell') return { ok: true, launch: { command: host.shell, commandArguments: [LOGIN_SHELL], workingFolder: checked.folder } };
  return agentLaunch(request.run, checked.folder, facts.pairs[request.run], host);
}

function listedFolder(asked: string, facts: PaneFacts, host: PaneHost): { ok: true; folder: string } | Refusal {
  if (!path.isAbsolute(asked)) return refuse('a pane needs an absolute path');
  const folder = path.resolve(asked);
  if (!facts.folders.includes(folder)) return refuse(unlistedFolder(folder));
  if (!host.isFolder(folder)) return refuse(`${folder} is not a folder on this machine`);
  return { ok: true, folder };
}

function agentLaunch(agent: JobsHost, folder: string, pair: JobsPair, host: PaneHost): Planned {
  const command = host.executable(agent);
  if (command === null) return refuse(`${agent} is not on the daemon's PATH; start it from a shell pane`);
  const error = modelRefusal(pair) ?? effortRefusal(agent, pair);
  if (error !== null) return refuse(error);
  return { ok: true, launch: { command, commandArguments: agentArguments(agent, pair), workingFolder: folder } };
}

function modelRefusal(pair: JobsPair): string | null {
  if (pair.model === null || MODEL.test(pair.model)) return null;
  return `${pair.from}.model must be a model name: letters, digits and . _ : -, not opening with -`;
}

function effortRefusal(agent: JobsHost, pair: JobsPair): string | null {
  const efforts = HOST_EFFORTS[agent] ?? [];
  if (pair.effort === null || efforts.includes(pair.effort)) return null;
  return `${pair.from}.effort on ${agent} must be one of ${efforts.join(', ')}`;
}

/** The agent's model and effort flags, as host_run in the plugin's lib/host.sh passes them; codex takes the roster's names mapped. */
function agentArguments(agent: JobsHost, pair: JobsPair): string[] {
  return agent === 'claude' ? claudeArguments(pair) : codexArguments(pair);
}

function claudeArguments({ model, effort }: JobsPair): string[] {
  return [...flagPair('--model', model), ...flagPair('--effort', effort)];
}

function codexArguments({ model, effort }: JobsPair): string[] {
  const mappedModel = model === null ? null : codexModel(model);
  const effortSetting = effort === null ? null : `model_reasoning_effort="${effort}"`;
  return [...flagPair('-m', mappedModel), ...flagPair('-c', effortSetting)];
}

function flagPair(flag: string, value: string | null): string[] {
  return value === null ? [] : [flag, value];
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
