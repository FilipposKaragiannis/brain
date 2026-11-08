import type { ItemState, WorktreeState } from '../../daemon/src/snapshot.ts';
import { ItemLink } from './links.tsx';
import type { ItemPages } from './links.tsx';

/** A worktree or item parked between steps: claimed, with no run, no agent and no gate, or held behind another item. */
export function isParked(state: WorktreeState | ItemState): state is 'waiting' | 'held' {
  return state === 'waiting' || state === 'held';
}

/**
 * What parked work waits for, in the words every screen uses: "held behind gh#12" with the holder
 * linked, or "waiting for a worker" and the step it runs next.
 */
export function ParkedLine({ heldBy, step, pages }: { heldBy: string | null; step: string; pages: ItemPages }) {
  if (heldBy !== null) return <>held behind <ItemLink id={heldBy} pages={pages} /></>;
  return <>waiting for a worker{step !== '' && <> · next <span className="mono">{step}</span></>}</>;
}
