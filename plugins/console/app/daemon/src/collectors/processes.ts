import path from 'node:path';
import type { AgentHost, AgentKind, ProcessListStatus, ProcessLookup, SessionActivity, SessionRef } from '../snapshot.ts';
import { LOOKUP_STDERR_CHARS, PROCESS_COMMAND_CHARS } from '../snapshot.ts';
import type { CommandResult, CommandRunner } from './exec.ts';
import { scriptEnvironment } from './exec.ts';

/**
 * `ppid` is its parent's pid, as ps gives it, and `parents` that parent and every pid above it the
 * same ps read lists, nearest first. `job` is the flow job it runs under, the nearest parent that
 * runs a job's script (see `jobOf`), or null. `cwd` is where it works (see `workingDirectory`).
 * `startedAt` is when ps says it started, worked out at the read. `session` and `activity` are
 * filled in by the monitor's session locator after the read; the process list alone never knows them.
 */
export type AgentProcess = {
  pid: number; ppid: number; parents: number[]; job: string | null; host: AgentHost; kind: AgentKind; cwd: string; elapsedSeconds: number; startedAt: string; command: string;
  session: SessionRef | null; activity: SessionActivity | null;
};
/** A process that was in one read and gone from the next, with when the read that missed it started. */
export type EndedProcess = AgentProcess & { endedAt: string };
/**
 * A process that can own a flow run, as flow's `_health.py is_host` says: a claude or codex (a
 * host's own servers aside) or the unattended loop. `startedAt` is when ps says it started, so a
 * pid a later process reused is told from the run's owner.
 */
export type HostProcess = { pid: number; command: string; startedAt: string };
/**
 * What one process read found: the agents and sessions with their working directory, every
 * process that can own a run whether or not its directory was found, and how complete the read was.
 */
export type ProcessFacts = { agents: AgentProcess[]; servers: ServerProcess[]; hosts: HostProcess[]; list: ProcessListStatus };
/**
 * A claude or codex host's own server (`NOT_AN_AGENT`): never an agent or a session, only shown
 * so the owner knows what runs. `label` names it in plain words, such as "Codex app server".
 */
export type ServerProcess = { pid: number; host: AgentHost; label: string; cwd: string; elapsedSeconds: number; startedAt: string; command: string };

const PROCESS_TIMEOUT_MS = 10000;
/** The columns both ps reads ask for, in the order `parseProcessList` reads them. */
const PS_COLUMNS = 'pid=,ppid=,etime=,command=';
const MILLISECONDS_PER_SECOND = 1000;
/** flow's unattended loop and the jobs that start runs, as `_health.py` matches them (`LOOP`). */
const UNATTENDED_LOOP = /run-unattended\.sh|jobs\/(next|comments)\.sh/;
/** flow's unattended loop, which the next job runs, and a job's own script, `jobs/<name>.sh`. */
const LOOP_SCRIPT = /(^|\/)run-unattended\.sh$/;
const JOB_SCRIPT = /(^|\/)jobs\/([a-z][a-z0-9-]*)\.sh$/;
/** The job the unattended loop runs for. */
const LOOP_JOB = 'next';
/** How many parents up an agent's job is looked for; flow's own chain is a handful deep. */
const MAX_PARENTS = 32;
const SECONDS_PER_MINUTE = 60;
const SECONDS_PER_HOUR = 3600;
const SECONDS_PER_DAY = 86400;
/** How lib/host.sh starts an unattended run: `claude -p <prompt>` or `codex exec`. */
const UNATTENDED_CLAUDE = / (-p|--print)( |$)/;
const UNATTENDED_CODEX = / exec( |$)/;
/**
 * Host daemons and servers that are never an agent or a session, wherever their cwd is: the
 * Claude daemon (`claude daemon run`), Claude's MCP server (`claude mcp serve`), and the Codex desktop app's `codex app-server --listen
 * unix://…`, its `codex app-server daemon pid-update-loop` and its cloud `exec-server`. Matched
 * only against the subcommand, the first word after the executable that is not an option, and
 * never in an unattended run: `claude -p mcp is broken` or `codex exec daemon fails` is an agent
 * whose prompt names a server.
 */
const NOT_AN_AGENT = ['daemon', 'mcp', 'app-server', 'exec-server'];
/** How many of the first words after the executable a server's label reads (`app-server daemon`). */
const SUBCOMMAND_WORDS = 2;
/** Options that take a value: `codex -c key=value app-server`. */
const OPTIONS_WITH_VALUE = ['-c', '--config'];
/** codex's options that name its working root: `codex exec -C <dir>`, `--cd <dir>` or `--cd=<dir>`. */
const CODEX_WORKING_ROOT = ['-C', '--cd'];
const CODEX_WORKING_ROOT_JOINED = '--cd=';
/**
 * App bundles and the folder the Claude desktop app keeps its CLI in. The executable runs past a
 * space only while the part beyond it is still one of these paths, so `sh /usr/local/bin/claude`
 * or `node …/claude` is a wrapper, never the host.
 */
const PATH_WITH_SPACES = ['.app/', 'Application Support/'];
const HOSTS: string[] = ['claude', 'codex'];
/** What each server is called, by its host and its first words; the first match names it. */
const SERVER_LABELS: { host: AgentHost; words: string[]; label: string }[] = [
  { host: 'codex', words: ['app-server', 'daemon'], label: 'Codex app server pid loop' },
  { host: 'codex', words: ['app-server'], label: 'Codex app server' },
  { host: 'codex', words: ['exec-server'], label: 'Codex exec server' },
  { host: 'claude', words: ['daemon'], label: 'Claude daemon' },
  { host: 'claude', words: ['mcp'], label: 'Claude MCP server' },
];
const HOST_NAMES: Record<AgentHost, string> = { claude: 'Claude', codex: 'Codex' };

/** The executable and its arguments. ps prints the command unquoted, so a path with spaces is rejoined. */
function splitCommand(command: string): { executable: string; args: string[] } {
  const tokens = command.split(' ').filter((token) => token.length > 0);
  let executable = tokens[0] ?? '';
  let next = 1;
  while (next < tokens.length) {
    const extended = `${executable} ${tokens[next]}`;
    const spansTheSpace = PATH_WITH_SPACES.some((marker) => {
      const at = extended.lastIndexOf(marker);
      return at >= 0 && at + marker.length > executable.length + 1;
    });
    if (!spansTheSpace) break;
    executable = extended;
    next += 1;
  }
  return { executable, args: tokens.slice(next) };
}

/** The first words after the executable that are not options, such as `app-server daemon`. */
function subcommands(args: string[]): string[] {
  const words: string[] = [];
  for (let index = 0; index < args.length && words.length < SUBCOMMAND_WORDS; index += 1) {
    const arg = args[index]!;
    if (OPTIONS_WITH_VALUE.includes(arg)) { index += 1; continue; }
    if (arg.startsWith('-')) continue;
    words.push(arg);
  }
  return words;
}

type ProcessRow = { pid: number; ppid: number; elapsedSeconds: number; command: string };

/** `ps -o pid=,ppid=,etime=,command=` rows. etime is `[[dd-]hh:]mm:ss`. */
export function parseProcessList(source: string): ProcessRow[] {
  const rows: ProcessRow[] = [];
  for (const line of source.split('\n')) {
    const match = /^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*)$/.exec(line);
    if (match === null) continue;
    rows.push({ pid: Number(match[1]), ppid: Number(match[2]), elapsedSeconds: parseElapsed(match[3]!), command: match[4]! });
  }
  return rows;
}

export function parseElapsed(elapsed: string): number {
  const [clock, days] = elapsed.split('-').reverse();
  const parts = (clock ?? '').split(':').map(Number).reverse();
  const seconds = (parts[0] ?? 0) + (parts[1] ?? 0) * SECONDS_PER_MINUTE + (parts[2] ?? 0) * SECONDS_PER_HOUR;
  return seconds + (days === undefined ? 0 : Number(days) * SECONDS_PER_DAY);
}

/** The host a command runs and the first words after it, or null when it runs neither claude nor codex. */
function hostCommand(command: string): { host: AgentHost; words: string[] } | null {
  const { executable, args } = splitCommand(command);
  const name = executable.slice(executable.lastIndexOf('/') + 1);
  if (!HOSTS.includes(name)) return null;
  return { host: name as AgentHost, words: subcommands(args) };
}

function isServer(host: AgentHost, words: string[], command: string): boolean {
  return NOT_AN_AGENT.includes(words[0] ?? '') && kindOf(host, command) !== 'agent';
}

export function hostOf(command: string): AgentHost | null {
  const parsed = hostCommand(command);
  if (parsed === null || isServer(parsed.host, parsed.words, command)) return null;
  return parsed.host;
}

/** The host and plain name of a claude or codex server, or null for anything else (an agent, a session, another program). */
export function serverOf(command: string): { host: AgentHost; label: string } | null {
  const parsed = hostCommand(command);
  if (parsed === null || !isServer(parsed.host, parsed.words, command)) return null;
  const { host, words } = parsed;
  const known = SERVER_LABELS.find((entry) => entry.host === host && entry.words.every((word, index) => words[index] === word));
  return { host, label: known?.label ?? `${HOST_NAMES[host]} ${words.join(' ')}` };
}

export function kindOf(host: AgentHost, command: string): AgentKind {
  const unattended = host === 'claude' ? UNATTENDED_CLAUDE : UNATTENDED_CODEX;
  return unattended.test(command) ? 'agent' : 'session';
}

/**
 * Where an agent works. `codex exec -C <dir>` (how flow's host.sh starts a Codex run) works in
 * `<dir>` but keeps the cwd it was started in, so lsof gives the launch folder, such as the
 * project root: for a codex exec the `-C`/`--cd` directory, resolved against that cwd, wins
 * when its argv names one. Every other process works in the cwd lsof gave. ps prints the argv
 * unquoted, so a directory with a space in it is cut at the space.
 */
function workingDirectory(host: AgentHost, kind: AgentKind, command: string, cwd: string): string {
  if (host !== 'codex' || kind !== 'agent') return cwd;
  const { args } = splitCommand(command);
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index]!;
    if (OPTIONS_WITH_VALUE.includes(arg)) { index += 1; continue; }
    if (arg.startsWith(CODEX_WORKING_ROOT_JOINED)) return path.resolve(cwd, arg.slice(CODEX_WORKING_ROOT_JOINED.length));
    const named = args[index + 1];
    if (CODEX_WORKING_ROOT.includes(arg) && named !== undefined) return path.resolve(cwd, named);
  }
  return cwd;
}

/**
 * The flow job a process runs as its script, or null: `next` for the unattended loop
 * (`run-unattended.sh`), else `<name>` for `jobs/<name>.sh`. The script is the program or its
 * first argument that is not an option (`/bin/sh …/jobs/comments.sh claude`), so a shell whose
 * `-c` string only names the script is not the job. A claude or codex never is, whatever its
 * prompt names (`claude -p jobs/comments.sh fails`).
 */
export function jobOf(command: string): string | null {
  if (hostCommand(command) !== null) return null;
  const { executable, args } = splitCommand(command);
  for (const word of [executable, args.find((arg) => !arg.startsWith('-')) ?? '']) {
    if (LOOP_SCRIPT.test(word)) return LOOP_JOB;
    const named = JOB_SCRIPT.exec(word);
    if (named !== null) return named[2]!;
  }
  return null;
}

/**
 * The pids above a row, nearest first, and the job of the nearest one that runs a flow job's
 * script, from the one ps read: a parent ps did not list, a loop or `MAX_PARENTS` ends the chain.
 */
function lineage(row: ProcessRow, byPid: Map<number, ProcessRow>): { parents: number[]; job: string | null } {
  const parents: number[] = [];
  let job: string | null = null;
  for (let parent = byPid.get(row.ppid); parent !== undefined && parents.length < MAX_PARENTS; parent = byPid.get(parent.ppid)) {
    if (parent.pid === row.pid || parents.includes(parent.pid)) break;
    parents.push(parent.pid);
    job ??= jobOf(parent.command);
  }
  return { parents, job };
}

/** `lsof -a -d cwd -Fpn` output: `p<pid>` lines followed by `n<path>` lines. */
export function parseWorkingDirectories(source: string): Map<number, string> {
  const directories = new Map<number, string>();
  let pid: number | null = null;
  for (const line of source.split('\n')) {
    if (line.startsWith('p')) { pid = Number(line.slice(1)); continue; }
    if (line.startsWith('n') && pid !== null) directories.set(pid, line.slice(1));
  }
  return directories;
}

/** The lookup as the snapshot and the log carry it. */
function lookupOf(command: ProcessLookup['command'], result: CommandResult, durationMs: number): ProcessLookup {
  return { command, code: result.code, timedOut: result.timedOut, durationMs, stderr: result.stderr.trim().slice(0, LOOKUP_STDERR_CHARS) };
}

/** How a lookup ended, in words: "ps timed out after 10s", "lsof exited 1: <its first stderr line>". */
function ending(lookup: ProcessLookup): string {
  if (lookup.timedOut) return `${lookup.command} timed out after ${PROCESS_TIMEOUT_MS / MILLISECONDS_PER_SECOND}s`;
  const said = lookup.stderr.split('\n')[0] ?? '';
  const exit = lookup.code === null ? `${lookup.command} ended with no exit code` : `${lookup.command} exited ${lookup.code}`;
  return said === '' ? exit : `${exit}: ${said}`;
}

/** A ps that did not list the processes: the whole list is unknown. */
function unavailable(reason: string, lookup: ProcessLookup): ProcessFacts {
  return { agents: [], servers: [], hosts: [], list: { status: 'unavailable', reason, lookup } };
}

/** When a row's process started, from its elapsed time at the read. */
function startOf(row: ProcessRow, readAt: number): string {
  return new Date(readAt - row.elapsedSeconds * MILLISECONDS_PER_SECOND).toISOString();
}

type Timed = { result: CommandResult; durationMs: number };

async function timed(runner: CommandRunner, clock: () => Date, command: ProcessLookup['command'], args: string[]): Promise<Timed> {
  const started = clock().getTime();
  const result = await runner({ command, args, cwd: '/', timeoutMs: PROCESS_TIMEOUT_MS, env: scriptEnvironment() });
  return { result, durationMs: clock().getTime() - started };
}

/**
 * Lists the claude and codex processes with their working directory, the hosts' own servers
 * apart from the agents and sessions. A ps that fails, times out
 * or lists nothing gives an `unavailable` list, never an empty one that would read as "nothing
 * runs"; an lsof that fails, times out or leaves a process out gives a `partial` one naming the
 * pids it could not place. The clock times the lookups and dates each process's start.
 */
export async function readProcesses(runner: CommandRunner, clock: () => Date): Promise<ProcessFacts> {
  const readAt = clock().getTime();
  const listing = await timed(runner, clock, 'ps', ['-axo', PS_COLUMNS]);
  const psLookup = lookupOf('ps', listing.result, listing.durationMs);
  if (listing.result.code !== 0 || listing.result.timedOut) return unavailable(ending(psLookup), psLookup);
  const rows = parseProcessList(listing.result.stdout);
  if (rows.length === 0) return unavailable('ps listed no processes', psLookup);
  const hosts = rows
    .filter((row) => hostOf(row.command) !== null || UNATTENDED_LOOP.test(row.command))
    .map((row) => ({ pid: row.pid, command: row.command.slice(0, PROCESS_COMMAND_CHARS), startedAt: startOf(row, readAt) }));
  const candidates = rows
    .map((row) => ({ row, host: hostOf(row.command) }))
    .filter((entry): entry is { row: ProcessRow; host: AgentHost } => entry.host !== null);
  const serving = rows
    .map((row) => ({ row, server: serverOf(row.command) }))
    .filter((entry): entry is { row: ProcessRow; server: { host: AgentHost; label: string } } => entry.server !== null);
  if (candidates.length === 0 && serving.length === 0) return { agents: [], servers: [], hosts, list: { status: 'complete' } };
  const pids = [...candidates, ...serving].map(({ row }) => String(row.pid)).join(',');
  const cwds = await timed(runner, clock, 'lsof', ['-a', '-d', 'cwd', '-Fpn', '-p', pids]);
  // lsof exits 1 when one of the pids has ended since ps, and still prints the others, so only a
  // pid it gave no directory for, or a timeout, makes the read partial. A server it could not
  // place is left out without that: the servers are only shown, never acted on.
  const directories = cwds.result.timedOut ? new Map<number, string>() : parseWorkingDirectories(cwds.result.stdout);
  const byPid = new Map(rows.map((row) => [row.pid, row]));
  const agents = candidates.flatMap(({ row, host }) => {
    const cwd = directories.get(row.pid);
    if (cwd === undefined) return [];
    const kind = kindOf(host, row.command);
    return [{ pid: row.pid, ppid: row.ppid, ...lineage(row, byPid), host, kind, cwd: workingDirectory(host, kind, row.command, cwd), elapsedSeconds: row.elapsedSeconds, startedAt: startOf(row, readAt), command: row.command.slice(0, PROCESS_COMMAND_CHARS), session: null, activity: null }];
  });
  const servers = serving.flatMap(({ row, server }) => {
    const cwd = directories.get(row.pid);
    if (cwd === undefined) return [];
    return [{ pid: row.pid, host: server.host, label: server.label, cwd, elapsedSeconds: row.elapsedSeconds, startedAt: startOf(row, readAt), command: row.command.slice(0, PROCESS_COMMAND_CHARS) }];
  });
  const unplaced = candidates.map(({ row }) => row.pid).filter((pid) => !directories.has(pid));
  if (unplaced.length === 0) return { agents, servers, hosts, list: { status: 'complete' } };
  const lsofLookup = lookupOf('lsof', cwds.result, cwds.durationMs);
  const missing = `no working directory for ${unplaced.length === 1 ? 'pid' : 'pids'} ${unplaced.join(', ')}`;
  const reason = lsofLookup.code === 0 && !lsofLookup.timedOut ? `lsof gave ${missing}` : `${ending(lsofLookup)}; ${missing}`;
  return { agents, servers, hosts, list: { status: 'partial', reason, unplaced, lookup: lsofLookup } };
}

/**
 * The interactive claude or codex session that runs as `pid` now, with when it started, or null
 * when ps lists no such pid, ps fails, or the pid runs anything else (an unattended agent, a
 * host's server, another program). A stop reads it again just before its signal, so a pid that a
 * later process took is never signalled.
 */
export async function readSession(runner: CommandRunner, clock: () => Date, pid: number): Promise<HostProcess | null> {
  const readAt = clock().getTime();
  const listing = await runner({ command: 'ps', args: ['-o', PS_COLUMNS, '-p', String(pid)], cwd: '/', timeoutMs: PROCESS_TIMEOUT_MS, env: scriptEnvironment() });
  if (listing.code !== 0 || listing.timedOut) return null;
  const row = parseProcessList(listing.stdout).find((entry) => entry.pid === pid);
  if (row === undefined) return null;
  const host = hostOf(row.command);
  if (host === null || kindOf(host, row.command) !== 'session') return null;
  return { pid, command: row.command.slice(0, PROCESS_COMMAND_CHARS), startedAt: startOf(row, readAt) };
}
