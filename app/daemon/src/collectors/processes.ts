import type { AgentHost, AgentKind } from '../snapshot.ts';
import { PROCESS_COMMAND_CHARS } from '../snapshot.ts';
import type { CommandRunner } from './exec.ts';
import { scriptEnvironment } from './exec.ts';

export type AgentProcess = { pid: number; host: AgentHost; kind: AgentKind; cwd: string; elapsedSeconds: number; command: string };
export type ProcessFacts = { agents: AgentProcess[] };

const PROCESS_TIMEOUT_MS = 10000;
const SECONDS_PER_MINUTE = 60;
const SECONDS_PER_HOUR = 3600;
const SECONDS_PER_DAY = 86400;
/** How lib/host.sh starts an unattended run: `claude -p <prompt>` or `codex exec`. */
const UNATTENDED_CLAUDE = / (-p|--print)( |$)/;
const UNATTENDED_CODEX = / exec( |$)/;
/**
 * Host daemons and servers that are never an agent or a session, wherever their cwd is: the
 * Claude daemon, and the Codex desktop app's `codex app-server --listen unix://…`, its
 * `codex app-server daemon pid-update-loop` and its cloud `exec-server`.
 */
const NOT_AN_AGENT = [' daemon run', ' daemon ', 'app-server', 'exec-server', 'pid-update-loop'];
/**
 * The executable is the first `…/claude` or `…/codex` path before any argument. Its folder may
 * hold spaces (the Claude desktop app keeps its CLI under `Application Support`), but a wrapper
 * such as `sh -c …/claude` has an argument before it and is not the host.
 */
const EXECUTABLE = /^((?:[^ ]| (?!-))*?\/)?(claude|codex)(?= |$)/;

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
  const executable = EXECUTABLE.exec(command)?.[2];
  if (executable !== 'claude' && executable !== 'codex') return null;
  if (NOT_AN_AGENT.some((marker) => command.includes(marker))) return null;
  return executable;
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

export async function readProcesses(runner: CommandRunner): Promise<ProcessFacts> {
  const env = scriptEnvironment();
  const listing = await runner({ command: 'ps', args: ['-axo', 'pid=,etime=,command='], cwd: '/', timeoutMs: PROCESS_TIMEOUT_MS, env });
  if (listing.code !== 0) return { agents: [] };
  const hosts = parseProcessList(listing.stdout)
    .map((row) => ({ row, host: hostOf(row.command) }))
    .filter((entry): entry is { row: ProcessRow; host: AgentHost } => entry.host !== null);
  if (hosts.length === 0) return { agents: [] };
  const pids = hosts.map(({ row }) => String(row.pid)).join(',');
  const cwds = await runner({ command: 'lsof', args: ['-a', '-d', 'cwd', '-Fpn', '-p', pids], cwd: '/', timeoutMs: PROCESS_TIMEOUT_MS, env });
  const directories = parseWorkingDirectories(cwds.stdout);
  return {
    agents: hosts.flatMap(({ row, host }) => {
      const cwd = directories.get(row.pid);
      if (cwd === undefined) return [];
      return [{ pid: row.pid, host, kind: kindOf(host, row.command), cwd, elapsedSeconds: row.elapsedSeconds, command: row.command.slice(0, PROCESS_COMMAND_CHARS) }];
    }),
  };
}
