import type { Counts, Readiness, Worktree } from '../../daemon/src/snapshot.ts';

type Clause = { count: number; singular: string; plural: string };

/**
 * One sentence on why open work does or does not run: what runs now, then how many items the
 * next job could take, wait on a field, wait at a gate, or are blocked. Empty buckets are left out.
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
  const clauses: Clause[] = [
    { count: readiness.ready, singular: 'is ready for the next job', plural: 'are ready for the next job' },
    { count: readiness.waitingOnField, singular: 'waits on a field', plural: 'wait on a field' },
    { count: readiness.gated, singular: 'waits at a gate', plural: 'wait at gates' },
    { count: readiness.blocked, singular: 'is blocked', plural: 'are blocked' },
  ];
  return clauses.filter((clause) => clause.count > 0).map((clause, index) => {
    const verb = clause.count === 1 ? clause.singular : clause.plural;
    if (index > 0) return `${clause.count} ${verb}`;
    return `${clause.count} ${clause.count === 1 ? 'item' : 'items'} ${verb}`;
  }).join(', ');
}
