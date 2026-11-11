import type { AgentHost, AgentKind, ProcessListStatus, ProcessLookup, SessionActivity, SessionRef, Subagent } from '../snapshot.ts';
import { LOOKUP_STDERR_CHARS, PROCESS_COMMAND_CHARS } from '../snapshot.ts';
import type { CommandResult, CommandRunner } from './exec.ts';
import { scriptEnvironment } from './exec.ts';
import { lineage, workingDirectory } from './agentContext.ts';
import { hostCommand } from './commandLine.ts';

/**
 * `parentPid` is its parent's pid, as ps gives it, and `parents` that parent and every pid above it
 * the same ps read lists, nearest first. `job` is the flow job it runs under, the nearest parent
 * that runs a job's script (see `jobOf`), or null. `cwd` is where it works (see `workingDirectory`).
 * `startedAt` is when ps says it started, worked out at the read. `session` and `activity` are
 * filled in by the monitor's session locator after the read, and `subagents` by its subagent reader
 * from that session; the process list alone never knows them.
 */
export type AgentProcess = {
  pid: number; parentPid: number; parents: number[]; job: string | null; host: AgentHost; kind: AgentKind; cwd: string; elapsedSeconds: number; startedAt: string; command: string;
  session: SessionRef | null; activity: SessionActivity | null; subagents: Subagent[];
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
/** What each server is called, by its host and its first words; the first match names it. */
const SERVER_LABELS: { host: AgentHost; words: string[]; label: string }[] = [
  { host: 'codex', words: ['app-server', 'daemon'], label: 'Codex app server pid loop' },
  { host: 'codex', words: ['app-server'], label: 'Codex app server' },
  { host: 'codex', words: ['exec-server'], label: 'Codex exec server' },
  { host: 'claude', words: ['daemon'], label: 'Claude daemon' },
  { host: 'claude', words: ['mcp'], label: 'Claude MCP server' },
];
const HOST_NAMES: Record<AgentHost, string> = { claude: 'Claude', codex: 'Codex' };

type ProcessRow = { pid: number; parentPid: number; elapsedSeconds: number; command: string };

/** `ps -o pid=,ppid=,etime=,command=` rows. etime is `[[dd-]hh:]mm:ss`. */
export function parseProcessList(source: string): ProcessRow[] {
  const rows: ProcessRow[] = [];
  for (const line of source.split('\n')) {
    const match = /^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*)$/.exec(line);
    if (match === null) continue;
    rows.push({ pid: Number(match[1]), parentPid: Number(match[2]), elapsedSeconds: parseElapsed(match[3]!), command: match[4]! });
  }
  return rows;
}

export function parseElapsed(elapsed: string): number {
  const [clock, days] = elapsed.split('-').reverse();
  const parts = (clock ?? '').split(':').map(Number).reverse();
  const seconds = (parts[0] ?? 0) + (parts[1] ?? 0) * SECONDS_PER_MINUTE + (parts[2] ?? 0) * SECONDS_PER_HOUR;
  return seconds + (days === undefined ? 0 : Number(days) * SECONDS_PER_DAY);
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
    return [{ pid: row.pid, parentPid: row.parentPid, ...lineage(row, byPid), host, kind, cwd: workingDirectory(host, kind, row.command, cwd), elapsedSeconds: row.elapsedSeconds, startedAt: startOf(row, readAt), command: row.command.slice(0, PROCESS_COMMAND_CHARS), session: null, activity: null, subagents: [] }];
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
