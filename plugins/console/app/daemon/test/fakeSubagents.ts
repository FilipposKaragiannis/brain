import type { SubagentReader } from '../src/collectors/subagents.ts';

/** A subagent reader that finds none, for a monitor in a test that does not look at subagents. */
export const noSubagents: Pick<SubagentReader, 'read'> = { read: async (sessions) => sessions.map(() => []) };
