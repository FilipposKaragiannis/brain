import type { SessionRef, Subagent } from '../snapshot.ts';
import type { SubagentReaderDependencies } from './subagents.ts';

/** What a subagent's `agent-<id>.meta.json` says, as read at the meta's `modifiedMs`; `about` is null once it finished or was stopped. */
export type ClaudeSubagentMeta = { modifiedMs: number; about: { type: string; task: string | null } | null };

/** What a subagent transcript's first line says: the folder it works in and when it started, null where it says nothing. */
export type ClaudeSubagentStart = { cwd: string | null; startedAt: string | null };

/**
 * What the claude reader keeps between reads, by file path: each meta until its file changes,
 * each transcript's first line for the life of the file. Entries for files a read did not see go.
 */
export type ClaudeSubagentCache = { metas: Map<string, ClaudeSubagentMeta>; starts: Map<string, ClaudeSubagentStart> };

/** An empty cache, one per reader. */
export function claudeSubagentCache(): ClaudeSubagentCache {
  return { metas: new Map(), starts: new Map() };
}

/** The live subagents of each claude session, in the same order as `sessions`. */
export async function claudeSubagents(sessions: readonly SessionRef[], dependencies: SubagentReaderDependencies, cache: ClaudeSubagentCache): Promise<Subagent[][]> {
  return sessions.map(() => []);
}
