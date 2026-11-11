/**
 * A subagent counts as live while its transcript was written this recently. A claude meta without
 * `finished`, or a codex child without `task_complete`, is no proof: a crashed or stopped session
 * leaves those behind for days. The readers' caches forget what no read used for as long.
 */
export const LIVE_WINDOW_MS = 10 * 60000;

/** A cache entry stamped with when a read last used it. */
export type UsedEntry = { seenMs: number };

/**
 * Drops the entries no read used within the live window. One reader serves every project and
 * each project reads only its own sessions, so an entry that only another project's read uses is
 * kept.
 */
export function forgetUnused<Entry extends UsedEntry>(entries: Map<string, Entry>, now: number): void {
  const oldest = now - LIVE_WINDOW_MS;
  for (const [file, entry] of [...entries]) if (entry.seenMs < oldest) entries.delete(file);
}
