import { execFile } from 'node:child_process';

/** One line of the process table: a process, its parent and its process group. */
export type ProcessEntry = { pid: number; parentPid: number; groupId: number };

const DECIMAL = 10;
const TABLE_COLUMNS = 3;

/**
 * The process groups a pane holds: the groups it knew of, and the group of every process that
 * descends from a process in one of them. A shell with job control runs each job in a group of
 * its own, and a job left once the shell ended keeps its group, so the known groups stay its roots.
 */
export function paneGroups(table: readonly ProcessEntry[], knownGroups: ReadonlySet<number>): Set<number> {
  const groups = new Set(knownGroups);
  const pane = new Set(table.filter((entry) => groups.has(entry.groupId)).map((entry) => entry.pid));
  let grown = true;
  while (grown) {
    grown = false;
    for (const entry of table) {
      if (pane.has(entry.pid) || !pane.has(entry.parentPid)) continue;
      pane.add(entry.pid);
      groups.add(entry.groupId);
      grown = true;
    }
  }
  return groups;
}

/** Every process the system lists, or none when `ps` fails or is cancelled. */
export function processTable(signal: AbortSignal): Promise<ProcessEntry[]> {
  return new Promise((resolve) => {
    execFile('ps', ['-A', '-o', 'pid=,ppid=,pgid='], { encoding: 'utf8', signal }, (error, stdout) => {
      resolve(error === null ? parseTable(stdout) : []);
    });
  });
}

function parseTable(listing: string): ProcessEntry[] {
  return listing.split('\n').flatMap((line) => {
    const numbers = line.trim().split(/\s+/).map((field) => Number.parseInt(field, DECIMAL));
    if (numbers.length !== TABLE_COLUMNS || numbers.some(Number.isNaN)) return [];
    const [pid, parentPid, groupId] = numbers as [number, number, number];
    return [{ pid, parentPid, groupId }];
  });
}
