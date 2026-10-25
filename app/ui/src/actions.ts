/**
 * The action contract the daemon serves under `/api/projects/:id/actions`. It lives here until it
 * joins the snapshot contract in the daemon.
 */
export type ActionKind =
  | 'gate.clear' | 'run.start'
  | 'job.run' | 'job.stop' | 'job.pause' | 'job.resume'
  | 'worktree.claim' | 'worktree.release'
  | 'steward.sweep' | 'steward.health'
  | 'pr.merge' | 'refresh';

export type ActionState = 'queued' | 'running' | 'done' | 'failed' | 'rejected';

export type ActionRecord = {
  id: string;
  kind: ActionKind;
  args: Record<string, string>;
  state: ActionState;
  command: string[];
  lock: string | null;
  requestedAt: string;
  startedAt: string | null;
  endedAt: string | null;
  exitCode: number | null;
  timedOut: boolean;
  outputTail: string;
  outputBytes: number;
  output?: string;
};

export const ACTIONS_KEPT = 50;

export function isActive(state: ActionState): boolean {
  return state === 'queued' || state === 'running';
}

/**
 * Whether an action is the one a button stands for: the same kind, and every argument the button
 * names has the same value. A gate's Answer button names the item, not the message it sends.
 */
export function matchesAction(kind: ActionKind, args: Record<string, string>, candidateKind: ActionKind, candidateArgs: Record<string, string>): boolean {
  return kind === candidateKind && Object.entries(args).every(([name, value]) => candidateArgs[name] === value);
}

/** Puts a record into the newest-first list, replacing the older copy and keeping full output already fetched. */
export function upsertAction(records: ActionRecord[], incoming: ActionRecord): ActionRecord[] {
  const previous = records.find((record) => record.id === incoming.id);
  const merged: ActionRecord = previous?.output !== undefined && incoming.output === undefined && !isActive(incoming.state)
    ? { ...incoming, output: previous.output }
    : incoming;
  const others = records.filter((record) => record.id !== incoming.id);
  return [merged, ...others].sort(newestFirst).slice(0, ACTIONS_KEPT);
}

function newestFirst(left: ActionRecord, right: ActionRecord): number {
  return Date.parse(right.requestedAt) - Date.parse(left.requestedAt);
}
