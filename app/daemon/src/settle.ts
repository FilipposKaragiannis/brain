import type { Disagreement, SourceName } from './snapshot.ts';

/** The source the daemon reads each store from. A store not listed here settles on any read. */
export const STORE_SOURCES: Record<string, SourceName> = {
  claim: 'files',
  'gate record': 'files',
  'run record': 'files',
  'process list': 'processes',
  'issue state': 'board',
  'issue labels': 'board',
  'pull request': 'pulls',
};

/**
 * Where the reads stand. Every read takes the next number when it starts. `started` is the last
 * number handed out; `completed` is, per source, the start number of the latest read that
 * finished and worked (0 before any). A failed read never counts: it says nothing new. `failing`
 * names the sources whose latest read failed: waiting on them could take forever, so a
 * disagreement naming one is not held back on its account, and the red source on the strip says
 * how far to trust it.
 */
export type ReadMarks = { started: number; completed: Record<SourceName, number>; failing: Record<SourceName, boolean> };

export function disagreementKey(disagreement: Disagreement): string {
  return [disagreement.sources.join('|'), disagreement.item ?? '', disagreement.worktree ?? '', disagreement.message].join('\u0000');
}

/**
 * Holds a disagreement back until it has survived a fresh read of every store it names. The
 * sources are read on different clocks (the board every two minutes, the files every thirty
 * seconds), so a claim or gate that just changed disagrees with the labels until the board is
 * read again; that is lag, not a disagreement. One per project, owned by its monitor.
 */
export class DisagreementSettler {
  /** Each disagreement still waiting, with the last read number handed out when it was first seen. */
  private readonly pending = new Map<string, number>();

  /**
   * The disagreements found in this rebuild that have settled: every store they name was read
   * by a read that started after they were first seen, so a read already in flight then (and
   * holding the old answer) never counts. Forgets any that went away.
   */
  settle(found: Disagreement[], reads: ReadMarks): Disagreement[] {
    const present = new Set<string>();
    const settled: Disagreement[] = [];
    for (const disagreement of found) {
      const key = disagreementKey(disagreement);
      present.add(key);
      const firstSeen = this.pending.get(key);
      if (firstSeen === undefined) { this.pending.set(key, reads.started); continue; }
      if (sourcesOf(disagreement).every((source) => reads.failing[source] || reads.completed[source] > firstSeen)) settled.push(disagreement);
    }
    for (const key of [...this.pending.keys()]) if (!present.has(key)) this.pending.delete(key);
    return settled;
  }
}

function sourcesOf(disagreement: Disagreement): SourceName[] {
  return disagreement.sources.flatMap((store) => {
    const source = STORE_SOURCES[store];
    return source === undefined ? [] : [source];
  });
}
