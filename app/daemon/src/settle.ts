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

/** How many times each source has been read, so far. */
export type ReadCounts = Record<SourceName, number>;

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
  /** Each disagreement still waiting, with the read counts when it was first seen. */
  private readonly pending = new Map<string, ReadCounts>();

  /** The disagreements found in this rebuild that have settled. Forgets any that went away. */
  settle(found: Disagreement[], reads: ReadCounts): Disagreement[] {
    const present = new Set<string>();
    const settled: Disagreement[] = [];
    for (const disagreement of found) {
      const key = disagreementKey(disagreement);
      present.add(key);
      const firstSeen = this.pending.get(key);
      if (firstSeen === undefined) { this.pending.set(key, { ...reads }); continue; }
      if (sourcesOf(disagreement).every((source) => reads[source] > firstSeen[source])) settled.push(disagreement);
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
