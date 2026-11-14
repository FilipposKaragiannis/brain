import path from 'node:path';
import type { PaneRun, PaneSize, PaneTarget } from './paneProtocol.ts';
import { DEFAULT_PANE_COLUMNS, DEFAULT_PANE_ROWS, MAXIMUM_PANE_COLUMNS, MAXIMUM_PANE_ROWS, MINIMUM_PANE_COLUMNS, MINIMUM_PANE_ROWS, PANE_RUNS, TARGET_FIELDS } from './paneProtocol.ts';
import { commandText, shellQuote } from './shellWords.ts';
import type { SessionRef } from './snapshot.ts';

/** A pane the page asks for: what it opens and the terminal's size. */
export type PaneRequest = { target: PaneTarget; size: PaneSize };
/** A process's session as the snapshot lists it: the folder it ran in, how to resume it, and whether the process still runs. */
export type SessionFacts = { pid: number; folder: string; session: SessionRef; alive: boolean };
/** The session the daemon located for a waiting gate from the transcripts on disk, and the worktree its step ran in. */
export type GateSessionFacts = { item: string; folder: string; session: SessionRef };
/**
 * What the project says about a pane: the root whose jobs' logs it follows, the folders a shell may
 * open in, the sessions of the agents and sessions the snapshot lists (alive) and of those that
 * ended since (not alive), and the sessions located for the gates it shows waiting.
 */
export type PaneFacts = { root: string; folders: string[]; sessions: SessionFacts[]; gateSessions: GateSessionFacts[] };
/** Where a shell pane may open: the project root, the pool worktrees, the other worktrees git lists and the folder of every listed agent and session. */
export type PanePlaces = { root: string; pool: string[]; outsideWorktrees: string[]; processFolders: string[] };
/** The machine the daemon runs on: the owner's shell, the environment every pane gets, and the disk. */
export type PaneHost = { shell: string; environment: Record<string, string>; isFolder(folder: string): boolean };
/**
 * The process a pane's pty runs: an argv and the folder it starts in. Only a resumed session runs
 * a shell line, through `/bin/sh -c`, with every word in it quoted.
 */
export type PaneLaunch = { command: string; commandArguments: string[]; workingFolder: string };

type Refusal = { ok: false; error: string };
type SizeBound = { key: 'cols' | 'rows'; fallback: number; minimum: number; maximum: number };
type Planned = { ok: true; launch: PaneLaunch } | Refusal;
type ParsedTarget = { ok: true; target: PaneTarget } | Refusal;
/** A session to hand the owner: the folder it ran in, its resume command, and whether its process still runs. */
type Resumable = { folder: string; resume: string[]; alive: boolean };

const COLUMNS: SizeBound = { key: 'cols', fallback: DEFAULT_PANE_COLUMNS, minimum: MINIMUM_PANE_COLUMNS, maximum: MAXIMUM_PANE_COLUMNS };
const ROWS: SizeBound = { key: 'rows', fallback: DEFAULT_PANE_ROWS, minimum: MINIMUM_PANE_ROWS, maximum: MAXIMUM_PANE_ROWS };
const WHOLE_NUMBER = /^[0-9]+$/;
const PID = /^[1-9][0-9]*$/;
/** A job's log name: a schedule (`next`, `next-nightly`) or one of its workers (`next-2`, `next-nightly-2`). */
const JOB_NAME = /^[a-z][a-z0-9-]*$/;
/** A login shell, because the environment launchd hands the daemon is thin. */
const LOGIN_SHELL = '-l';
/** By path, so a `tail` earlier on the PATH is never the one that runs. */
const TAIL = '/usr/bin/tail';
/** How much of a job's log a pane shows before it follows new lines. */
const LOG_LINES = '200';
/** Where a job writes its log, under the project root. */
const JOB_LOG_FOLDER = path.join('.flow', 'log');
/** The shell a resumed session's line runs in: POSIX, so the quoting is the same whatever the owner's shell. */
const POSIX_SHELL = '/bin/sh';
const RUN_LINE = '-c';
const STILL_RUNNING = 'The run is still going. Once it ends, resume its session with:';
/** The daemon's variables a pane inherits; nothing else, so no token reaches a pane. */
const INHERITED_VARIABLES = ['PATH', 'HOME', 'USER', 'LOGNAME', 'SHELL', 'TMPDIR', 'LANG', 'LC_ALL', 'SSH_AUTH_SOCK'];
const DEFAULT_LANGUAGE = 'en_US.UTF-8';
const TERMINAL_VARIABLES = { TERM: 'xterm-256color', COLORTERM: 'truecolor' };

const refuse = (error: string): Refusal => ({ ok: false, error });
const sizeRefusal = (bound: SizeBound): string => `${bound.key} must be a whole number from ${bound.minimum} to ${bound.maximum}`;
const notAFolder = (folder: string): string => `${folder} is not a folder on this machine`;
const launchIn = (workingFolder: string, command: string, commandArguments: string[]): Planned => ({ ok: true, launch: { command, commandArguments, workingFolder } });

/** The places a shell pane may open, resolved. */
export function paneFolders(places: PanePlaces): string[] {
  return [places.root, ...places.pool, ...places.outsideWorktrees, ...places.processFolders].map((entry) => path.resolve(entry));
}

/** The refusal for a folder `paneFolders` does not list. */
export function unlistedFolder(folder: string): string {
  return `${folder} is not the project root, a worktree the console lists or the folder of a listed agent or session`;
}

/**
 * Reads a pane's request from its query: `run`, then `path` for a shell, `job` for a job's log,
 * `session` (a pid) and `path` for a session, `gate` (an item) for a gate's session; and `cols`
 * and `rows` (80 by 24 when absent).
 */
export function parsePaneRequest(query: URLSearchParams): { ok: true; request: PaneRequest } | Refusal {
  const asked = query.get('run');
  const run = PANE_RUNS.find((known) => known === asked) ?? null;
  if (run === null) return refuse(`run must be one of ${PANE_RUNS.join(', ')}`);
  const parsed = parseTarget(run, query);
  if (!parsed.ok) return parsed;
  const columns = sizeValue(query, COLUMNS);
  if (columns === null) return refuse(sizeRefusal(COLUMNS));
  const rows = sizeValue(query, ROWS);
  if (rows === null) return refuse(sizeRefusal(ROWS));
  return { ok: true, request: { target: parsed.target, size: { columns, rows } } };
}

function parseTarget(run: PaneRun, query: URLSearchParams): ParsedTarget {
  const folder = query.get(TARGET_FIELDS.folder) ?? '';
  switch (run) {
    case 'shell': return folder === '' ? refuse('a shell pane needs a path') : { ok: true, target: { run, folder } };
    case 'job': return jobTarget(query.get(TARGET_FIELDS.job) ?? '');
    case 'session': return sessionTarget(folder, query.get(TARGET_FIELDS.pid) ?? '');
    case 'gate': return gateTarget(query.get(TARGET_FIELDS.item) ?? '');
  }
}

function jobTarget(job: string): ParsedTarget {
  return JOB_NAME.test(job) ? { ok: true, target: { run: 'job', job } } : refuse('a job pane needs a job name like next or health');
}

function sessionTarget(folder: string, pid: string): ParsedTarget {
  if (!PID.test(pid)) return refuse('session must be the pid of an agent or session the console lists');
  if (folder === '') return refuse('a session pane needs the path the session ran in');
  return { ok: true, target: { run: 'session', folder, pid: Number(pid) } };
}

function gateTarget(item: string): ParsedTarget {
  return item === '' ? refuse('a gate pane needs the item the gate waits on') : { ok: true, target: { run: 'gate', item } };
}

/**
 * The launch for a pane, or why the daemon refuses it. A shell is the owner's login shell, only in
 * a folder the snapshot lists and the disk holds. A job's log is followed from the project root.
 * A session (by its pid, in the folder it ran in) or a gate's session (the one the daemon located
 * for a waiting gate) is resumed: see `resumeLaunch`.
 */
export function planPane(request: PaneRequest, facts: PaneFacts, host: PaneHost): Planned {
  const { target } = request;
  switch (target.run) {
    case 'shell': return shellLaunch(target.folder, facts, host);
    case 'job': return jobLogLaunch(target.job, facts);
    case 'session': return sessionLaunch(target.pid, target.folder, facts, host);
    case 'gate': return gateLaunch(target.item, facts, host);
  }
}

function shellLaunch(asked: string, facts: PaneFacts, host: PaneHost): Planned {
  if (!path.isAbsolute(asked)) return refuse('a pane needs an absolute path');
  const folder = path.resolve(asked);
  if (!facts.folders.includes(folder)) return refuse(unlistedFolder(folder));
  if (!host.isFolder(folder)) return refuse(notAFolder(folder));
  return launchIn(folder, host.shell, [LOGIN_SHELL]);
}

/** `-F`, not `-f`: a job that never ran has no log yet, and `tail -F` waits for it, silent, then follows it across rotation. */
function jobLogLaunch(job: string, facts: PaneFacts): Planned {
  const root = path.resolve(facts.root);
  return launchIn(root, TAIL, ['-n', LOG_LINES, '-F', path.join(root, JOB_LOG_FOLDER, `${job}.log`)]);
}

/** Only a session the snapshot lists, and only in its own folder: `claude --resume` finds a session by the folder it was started in. */
function sessionLaunch(pid: number, asked: string, facts: PaneFacts, host: PaneHost): Planned {
  const found = facts.sessions.find((entry) => entry.pid === pid);
  if (found === undefined) return refuse(`the console knows no session for pid ${pid}: its transcript was not found, or it ended over a day ago`);
  const folder = path.resolve(found.folder);
  if (!path.isAbsolute(asked) || path.resolve(asked) !== folder) return refuse(`pid ${pid} ran in ${found.folder}; its session opens there, not in ${asked}`);
  return resumeLaunch({ folder, resume: found.session.resume, alive: found.alive }, host);
}

/** The step that raised the gate has ended, so its session resumes at once, unless a process the snapshot lists still runs it. */
function gateLaunch(item: string, facts: PaneFacts, host: PaneHost): Planned {
  const found = facts.gateSessions.find((entry) => entry.item === item);
  if (found === undefined) return refuse(`the console located no session for a gate on ${item}: no gate waits on it, it has no claimed worktree, or no transcript there was written around the time it was raised`);
  const alive = facts.sessions.some((entry) => entry.alive && entry.session.transcript === found.session.transcript);
  return resumeLaunch({ folder: path.resolve(found.folder), resume: found.session.resume, alive }, host);
}

/**
 * A session handed to the owner in its folder. While its process still runs the resume command is
 * printed, not run (two writers on one session); once the process has ended it runs at once.
 * Either way the owner's login shell follows, so the pane stays a terminal.
 */
function resumeLaunch(session: Resumable, host: PaneHost): Planned {
  if (!host.isFolder(session.folder)) return refuse(notAFolder(session.folder));
  const typed = commandText(session.resume);
  const first = session.alive ? `echo ${shellQuote(STILL_RUNNING)} && echo ${shellQuote(typed)}` : typed;
  return launchIn(session.folder, POSIX_SHELL, [RUN_LINE, `${first}; exec ${shellQuote(host.shell)} ${LOGIN_SHELL}`]);
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
