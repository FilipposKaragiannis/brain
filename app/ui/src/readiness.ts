import type { Counts, Readiness, Worktree } from '../../daemon/src/snapshot.ts';

/** One part of the sentence after its number: how it reads first (naming the items) and later, for one and for many. */
type Clause = { count: number; first: [string, string]; later: [string, string] };

/**
 * One sentence on why open work does or does not run: what runs now, then how many items the
 * next job could take, are next in line but lack a field, lack one further back in the backlog,
 * wait at a gate, or are blocked. Empty buckets are left out.
 */
export function readinessSentence(readiness: Readiness, counts: Counts, worktrees: readonly Worktree[]): string {
  const waiting = waitingClauses(readiness);
  const running = runningPart(counts, worktrees);
  if (running === null) return waiting === '' ? 'Nothing runs, and no open item waits.' : `Nothing runs: ${waiting}.`;
  return waiting === '' ? `${running}.` : `${running}; ${waiting}.`;
}

function runningPart(counts: Counts, worktrees: readonly Worktree[]): string | null {
  const parts: string[] = [];
  const running = worktrees.filter((worktree) => worktree.state === 'running').map((worktree) => worktree.item ?? worktree.name);
  if (running.length > 0) parts.push(`${running.join(', ')} ${running.length === 1 ? 'runs' : 'run'} now`);
  if (counts.jobsRunning > 0) parts.push(`${counts.jobsRunning} ${counts.jobsRunning === 1 ? 'job runs' : 'jobs run'}`);
  return parts.length === 0 ? null : parts.join(', ');
}

function waitingClauses(readiness: Readiness): string {
  const nextInLine = readiness.nextInLineMissingField;
  const backlog = Math.max(0, readiness.waitingOnField - nextInLine);
  const backlogClause: Clause = nextInLine > 0
    ? { count: backlog, first: ['more in the backlog lacks one', 'more in the backlog lack one'], later: ['more in the backlog lacks one', 'more in the backlog lack one'] }
    : { count: backlog, first: ['item in the backlog lacks a field', 'items in the backlog lack a field'], later: ['in the backlog lacks a field', 'in the backlog lack a field'] };
  const clauses: Clause[] = [
    { count: readiness.ready, first: ['item is ready for the next job', 'items are ready for the next job'], later: ['is ready for the next job', 'are ready for the next job'] },
    { count: nextInLine, first: ['item that is next in line lacks a field', 'items that are next in line lack a field'], later: ['next in line lacks a field', 'next in line lack a field'] },
    backlogClause,
    { count: readiness.gated, first: ['item waits at a gate', 'items wait at gates'], later: ['waits at a gate', 'wait at gates'] },
    { count: readiness.blocked, first: ['item is blocked', 'items are blocked'], later: ['is blocked', 'are blocked'] },
  ];
  return clauses.filter((clause) => clause.count > 0).map((clause, index) => {
    const forms = index === 0 ? clause.first : clause.later;
    return `${clause.count} ${clause.count === 1 ? forms[0] : forms[1]}`;
  }).join(', ');
}
