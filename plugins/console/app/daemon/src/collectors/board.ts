import path from 'node:path';
import type { CommandRunner } from './exec.ts';
import { scriptEnvironment } from './exec.ts';

/** One item of `board.sh --json`, without its body, which `BoardFacts.bodies` keeps apart. */
export type BoardItem = {
  id: string;
  kind: string;
  title: string;
  size: string;
  priority: string;
  rank: number;
  needs: string[];
  status: string;
  labels: string[];
  blocked_by: string[];
  open_blockers: string[];
  open_children: number;
  parent: string;
  url: string;
  state: { step: string; gate: string; worktree: string; pr: string; last_event: string; profile: string; attempts: number };
};

/** One item's spend from `board.sh --json`: the step sessions in flow's runs.jsonl, summed. */
export type BoardSpend = { cost_usd: number; sessions: number; tokens: number };

/**
 * The items, each item's body by id (kept apart so only the screens that show a body carry one),
 * and each item's spend by id, empty on a plugin before flow 1.22.0.
 */
export type BoardFacts = { items: BoardItem[]; bodies: Record<string, string>; spend: Record<string, BoardSpend> };

/** The board asks the tracker for every item; on a GitHub project that takes tens of seconds. */
const BOARD_TIMEOUT_MS = 180000;

/** The rank `_board.py` sorts an item without one by. */
export const UNRANKED = 999;

/** What an adapter prints: an item that may lack the fields the board computes. */
type AdapterItem = Omit<BoardItem, 'rank' | 'needs' | 'open_blockers'> & Partial<Pick<BoardItem, 'rank' | 'needs' | 'open_blockers'>> & { body?: string };

/**
 * An adapter may leave out rank, needs and open_blockers (the local one has no open_blockers), so
 * an item without them gets the board's sort default, no needs, and the blockers that are open
 * items on this board.
 */
export function parseBoard(source: string): BoardFacts {
  const parsed = JSON.parse(source) as { items?: unknown; spend?: unknown };
  const items = Array.isArray(parsed.items) ? (parsed.items as AdapterItem[]) : [];
  const bodies = Object.fromEntries(items.filter((item) => typeof item.body === 'string').map((item) => [item.id, item.body as string]));
  const open = new Set(items.filter((item) => item.status === 'open').map((item) => item.id));
  return {
    items: items.map(({ body: _body, rank, needs, open_blockers, ...item }) => ({
      ...item,
      rank: rank ?? UNRANKED,
      needs: needs ?? [],
      open_blockers: open_blockers ?? item.blocked_by.filter((id) => open.has(id)),
    })),
    bodies,
    spend: parseSpend(parsed.spend),
  };
}

/** The spend map, keeping only the entries whose three fields are numbers. */
function parseSpend(value: unknown): Record<string, BoardSpend> {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) return {};
  return Object.fromEntries(Object.entries(value as Record<string, unknown>).flatMap(([id, entry]) => {
    const spend = entry as Partial<BoardSpend> | null;
    const numbers = spend !== null && typeof spend === 'object' && [spend.cost_usd, spend.sessions, spend.tokens].every((field) => typeof field === 'number');
    return numbers ? [[id, { cost_usd: spend.cost_usd as number, sessions: spend.sessions as number, tokens: spend.tokens as number }]] : [];
  }));
}

export async function readBoard(root: string, pluginRoot: string, runner: CommandRunner): Promise<BoardFacts> {
  const result = await runner({
    command: 'sh',
    args: [path.join(pluginRoot, 'scripts', 'board.sh'), '--json'],
    cwd: root,
    timeoutMs: BOARD_TIMEOUT_MS,
    env: scriptEnvironment(),
  });
  if (result.code !== 0) throw new Error(`board.sh --json failed: ${result.stderr.trim() || result.code}`);
  return parseBoard(result.stdout);
}
