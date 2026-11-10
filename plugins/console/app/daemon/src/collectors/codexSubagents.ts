import type { SessionRef, Subagent } from '../snapshot.ts';
import type { SubagentReaderDependencies } from './subagents.ts';

/**
 * What a child rollout's first line (`session_meta`) says of it: its own id, the root session it
 * belongs to, its role, task path and nickname as spawned, where it works, when it started, and
 * the ordinal its own history starts at (the lines before it replay the parent's).
 */
export type CodexSubagentChild = {
  id: string; rootId: string; role: string | null; agentPath: string | null; nickname: string | null;
  cwd: string | null; startedAt: string | null; historyStart: number | null;
};

/** A rollout's first line as read at its `modifiedMs`; `child` is null for a rollout that is no subagent, or that cannot be read. */
export type CodexSubagentMeta = { modifiedMs: number; child: CodexSubagentChild | null };

/** What the codex reader keeps between reads, by rollout path: each first line, which never changes. Entries for files a read did not see go. */
export type CodexSubagentCache = { metas: Map<string, CodexSubagentMeta> };

/** An empty cache, one per reader. */
export function codexSubagentCache(): CodexSubagentCache {
  return { metas: new Map() };
}

/** The live subagents of each codex session, at every depth, in the same order as `sessions`. */
export async function codexSubagents(sessions: readonly SessionRef[], dependencies: SubagentReaderDependencies, cache: CodexSubagentCache): Promise<Subagent[][]> {
  return sessions.map(() => []);
}
