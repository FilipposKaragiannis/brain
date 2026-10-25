/** The action contract is the daemon's; this module adds what the UI does with it. */
import type { ActionKind, ActionRecord, ActionState } from '../../daemon/src/snapshot.ts';

export type { ActionKind, ActionRecord, ActionState };

export const ACTIONS_KEPT = 50;

export function isActive(state: ActionState): boolean {
  return state === 'running';
}

/** The word a record shows: `started` for one that handed its work on (a job given to launchd), else its state. */
export function actionStateLabel(record: ActionRecord): string {
  if (record.state === 'done' && record.outcome === 'started') return 'started';
  return record.state;
}

/**
 * Whether an action is the one a button stands for: the same kind, and every argument the button
 * names has the same value. A gate's Answer button names the item, not the message it sends.
 * Open in Terminal matches only the same arguments exactly.
 */
export function matchesAction(kind: ActionKind, args: Record<string, string>, candidateKind: ActionKind, candidateArgs: Record<string, string>): boolean {
  if (kind !== candidateKind) return false;
  const named = Object.entries(args).every(([name, value]) => candidateArgs[name] === value);
  // Open in Terminal on the root and a job's Open in Terminal (the root and a job) are two buttons: every argument must match.
  if (kind === EXACT_KIND) return named && Object.keys(candidateArgs).length === Object.keys(args).length;
  return named;
}

/** The kind whose buttons differ only by an extra argument, so a match takes them all. */
const EXACT_KIND: ActionKind = 'terminal.open';

/**
 * Puts a record into the newest-first list, replacing the older copy. Updates can arrive out of
 * order (a late POST reply after the stream already said done), so a record never moves from a
 * final state back to running, and of two final copies the later `endedAt` wins. Full output
 * already fetched is kept.
 */
export function upsertAction(records: ActionRecord[], incoming: ActionRecord): ActionRecord[] {
  const previous = records.find((record) => record.id === incoming.id);
  const winner = previous === undefined || isNewer(incoming, previous) ? incoming : previous;
  const merged: ActionRecord = winner.output === undefined && previous?.output !== undefined && !isActive(winner.state)
    ? { ...winner, output: previous.output }
    : winner;
  const others = records.filter((record) => record.id !== incoming.id);
  return [merged, ...others].sort(newestFirst).slice(0, ACTIONS_KEPT);
}

function isNewer(incoming: ActionRecord, previous: ActionRecord): boolean {
  if (isActive(previous.state)) return true;
  if (isActive(incoming.state)) return false;
  if (incoming.endedAt === null || previous.endedAt === null) return true;
  return Date.parse(incoming.endedAt) >= Date.parse(previous.endedAt);
}

/**
 * The list after a reconnect: the daemon's fresh list, merged in. A record still running here but
 * missing from the daemon's list ended while the stream was down, or died with a daemon restart
 * (records live in its memory only), so it no longer counts as running and is dropped.
 */
export function reconcileActions(records: ActionRecord[], fresh: ActionRecord[]): ActionRecord[] {
  const known = new Set(fresh.map((record) => record.id));
  const kept = records.filter((record) => known.has(record.id) || !isActive(record.state));
  return fresh.reduce((merged, record) => upsertAction(merged, record), kept);
}

function newestFirst(left: ActionRecord, right: ActionRecord): number {
  return Date.parse(right.requestedAt) - Date.parse(left.requestedAt);
}
