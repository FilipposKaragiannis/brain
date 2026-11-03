import type { AgentHost, AgentKind, ProcessListStatus, ProcessLookup, SessionRef } from '../snapshot.ts';
import { LOOKUP_STDERR_CHARS, PROCESS_COMMAND_CHARS } from '../snapshot.ts';
import type { CommandResult, CommandRunner } from './exec.ts';
import { scriptEnvironment } from './exec.ts';

/** `session` is filled in by the monitor's session locator after the read; the process list alone never knows it. */
export type AgentProcess = { pid: number; host: AgentHost; kind: AgentKind; cwd: string; elapsedSeconds: number; command: string; session: SessionRef | null };
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
export type ProcessFacts = { agents: AgentProcess[]; hosts: HostProcess[]; list: ProcessListStatus };

const PROCESS_TIMEOUT_MS = 10000;
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
 * Claude daemon (`claude daemon run`), and the Codex desktop app's `codex app-server --listen
 * unix://…`, its `codex app-server daemon pid-update-loop` and its cloud `exec-server`. Matched
 * only against the first words after the executable, so a prompt that mentions one is still an agent.
 */
const NOT_AN_AGENT = ['daemon', 'app-server', 'exec-server', 'pid-update-loop'];
/** How many of the first words after the executable name a host's server. */
const SUBCOMMAND_WORDS = 2;
/** Options that take a value: `codex -c key=value app-server`. */
const OPTIONS_WITH_VALUE = ['-c', '--config'];
/**
 * App bundles and the folder the Claude desktop app keeps its CLI in. The executable runs past a
 * space only while the part beyond it is still one of these paths, so `sh /usr/local/bin/claude`
 * or `node …/claude` is a wrapper, never the host.
 */
const PATH_WITH_SPACES = ['.app/', 'Application Support/'];
const HOSTS: string[] = ['claude', 'codex'];

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

type ProcessRow = { pid: number; elapsedSeconds: number; command: string };

/** `ps -axo pid=,etime=,command=` rows. etime is `[[dd-]hh:]mm:ss`. */
export function parseProcessList(source: string): ProcessRow[] {
  const rows: ProcessRow[] = [];
  for (const line of source.split('\n')) {
    const match = /^\s*(\d+)\s+(\S+)\s+(.*)$/.exec(line);
    if (match === null) continue;
    rows.push({ pid: Number(match[1]), elapsedSeconds: parseElapsed(match[2]!), command: match[3]! });
  }
  return rows;
}

export function parseElapsed(elapsed: string): number {
  const [clock, days] = elapsed.split('-').reverse();
  const parts = (clock ?? '').split(':').map(Number).reverse();
  const seconds = (parts[0] ?? 0) + (parts[1] ?? 0) * SECONDS_PER_MINUTE + (parts[2] ?? 0) * SECONDS_PER_HOUR;
  return seconds + (days === undefined ? 0 : Number(days) * SECONDS_PER_DAY);
}

export function hostOf(command: string): AgentHost | null {
  const { executable, args } = splitCommand(command);
  const name = executable.slice(executable.lastIndexOf('/') + 1);
  if (!HOSTS.includes(name)) return null;
  if (subcommands(args).some((word) => NOT_AN_AGENT.includes(word))) return null;
  return name as AgentHost;
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
  return { agents: [], hosts: [], list: { status: 'unavailable', reason, lookup } };
}

type Timed = { result: CommandResult; durationMs: number };

async function timed(runner: CommandRunner, clock: () => Date, command: ProcessLookup['command'], args: string[]): Promise<Timed> {
  const started = clock().getTime();
  const result = await runner({ command, args, cwd: '/', timeoutMs: PROCESS_TIMEOUT_MS, env: scriptEnvironment() });
  return { result, durationMs: clock().getTime() - started };
}

/**
 * Lists the claude and codex processes with their working directory. A ps that fails, times out
 * or lists nothing gives an `unavailable` list, never an empty one that would read as "nothing
 * runs"; an lsof that fails, times out or leaves a process out gives a `partial` one naming the
 * pids it could not place. The clock times the lookups and dates each process's start.
 */
export async function readProcesses(runner: CommandRunner, clock: () => Date): Promise<ProcessFacts> {
  const readAt = clock().getTime();
  const listing = await timed(runner, clock, 'ps', ['-axo', 'pid=,etime=,command=']);
  const psLookup = lookupOf('ps', listing.result, listing.durationMs);
  if (listing.result.code !== 0 || listing.result.timedOut) return unavailable(ending(psLookup), psLookup);
  const rows = parseProcessList(listing.result.stdout);
  if (rows.length === 0) return unavailable('ps listed no processes', psLookup);
  const hosts = rows
    .filter((row) => hostOf(row.command) !== null || UNATTENDED_LOOP.test(row.command))
    .map((row) => ({ pid: row.pid, command: row.command.slice(0, PROCESS_COMMAND_CHARS), startedAt: new Date(readAt - row.elapsedSeconds * MILLISECONDS_PER_SECOND).toISOString() }));
  const candidates = rows
    .map((row) => ({ row, host: hostOf(row.command) }))
    .filter((entry): entry is { row: ProcessRow; host: AgentHost } => entry.host !== null);
  if (candidates.length === 0) return { agents: [], hosts, list: { status: 'complete' } };
  const pids = candidates.map(({ row }) => String(row.pid)).join(',');
  const cwds = await timed(runner, clock, 'lsof', ['-a', '-d', 'cwd', '-Fpn', '-p', pids]);
  // lsof exits 1 when one of the pids has ended since ps, and still prints the others, so only a
  // pid it gave no directory for, or a timeout, makes the read partial.
  const directories = cwds.result.timedOut ? new Map<number, string>() : parseWorkingDirectories(cwds.result.stdout);
  const agents = candidates.flatMap(({ row, host }) => {
    const cwd = directories.get(row.pid);
    if (cwd === undefined) return [];
    return [{ pid: row.pid, host, kind: kindOf(host, row.command), cwd, elapsedSeconds: row.elapsedSeconds, command: row.command.slice(0, PROCESS_COMMAND_CHARS), session: null }];
  });
  const unplaced = candidates.map(({ row }) => row.pid).filter((pid) => !directories.has(pid));
  if (unplaced.length === 0) return { agents, hosts, list: { status: 'complete' } };
  const lsofLookup = lookupOf('lsof', cwds.result, cwds.durationMs);
  const missing = `no working directory for ${unplaced.length === 1 ? 'pid' : 'pids'} ${unplaced.join(', ')}`;
  const reason = lsofLookup.code === 0 && !lsofLookup.timedOut ? `lsof gave ${missing}` : `${ending(lsofLookup)}; ${missing}`;
  return { agents, hosts, list: { status: 'partial', reason, unplaced, lookup: lsofLookup } };
}
