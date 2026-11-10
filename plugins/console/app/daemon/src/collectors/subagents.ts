import type { AgentHost, SessionRef, Subagent } from '../snapshot.ts';
import type { ClaudeSubagentCache } from './claudeSubagents.ts';
import { claudeSubagentCache, claudeSubagents } from './claudeSubagents.ts';
import type { CodexSubagentCache } from './codexSubagents.ts';
import { codexSubagentCache, codexSubagents } from './codexSubagents.ts';
import type { SessionFiles } from './sessions.ts';

/** What the subagent readers read: the home the hosts write under, the clock their live window counts on, and the disk. */
export type SubagentReaderDependencies = { home: string; clock: () => Date; files: SessionFiles };

/**
 * Lists the subagents each claude and codex session runs now. Each host's reader gets every
 * session of its host in one call, on every read. One reader serves every project and each
 * project reads only its own sessions, so the caches forget a file once no read used it for the
 * live window (`LIVE_WINDOW_MS`), not when one read leaves it out; the caches live as long as
 * this reader.
 */
export class SubagentReader {
  private readonly dependencies: SubagentReaderDependencies;
  private readonly claudeCache: ClaudeSubagentCache = claudeSubagentCache();
  private readonly codexCache: CodexSubagentCache = codexSubagentCache();

  constructor(dependencies: SubagentReaderDependencies) { this.dependencies = dependencies; }

  /** The live subagents of each session, in the same order; empty where there is no session. */
  async read(sessions: readonly (SessionRef | null)[]): Promise<Subagent[][]> {
    const claude = sessionsOf(sessions, 'claude');
    const codex = sessionsOf(sessions, 'codex');
    const [claudeRows, codexRows] = await Promise.all([
      claudeSubagents(claude.map(({ session }) => session), this.dependencies, this.claudeCache),
      codexSubagents(codex.map(({ session }) => session), this.dependencies, this.codexCache),
    ]);
    const rows = new Map<number, Subagent[]>([
      ...claude.map(({ index }, position) => [index, claudeRows[position] ?? []] as const),
      ...codex.map(({ index }, position) => [index, codexRows[position] ?? []] as const),
    ]);
    return sessions.map((session, index) => rows.get(index) ?? []);
  }
}

/** The sessions of one host, each with its place in the list read. */
function sessionsOf(sessions: readonly (SessionRef | null)[], host: AgentHost): { index: number; session: SessionRef }[] {
  return sessions.flatMap((session, index) => (session?.host === host ? [{ index, session }] : []));
}

/** A reader that finds no subagents, for a monitor built without one (tests that do not look at subagents). */
export const noSubagents: Pick<SubagentReader, 'read'> = { read: async (sessions) => sessions.map(() => []) };
