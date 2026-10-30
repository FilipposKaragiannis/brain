import path from 'node:path';
import type { CommandRunner } from './exec.ts';
import { scriptEnvironment } from './exec.ts';

/** One item of `board.sh --json`, without its body. */
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

export type BoardFacts = { items: BoardItem[] };

/** The board asks the tracker for every item; on a GitHub project that takes tens of seconds. */
const BOARD_TIMEOUT_MS = 180000;

/** The rank `_board.py` sorts an item without one by. */
export const UNRANKED = 999;

/** What the local adapter prints: the GitHub adapter's item without the fields it computes. */
type AdapterItem = Omit<BoardItem, 'rank' | 'needs' | 'open_blockers'> & Partial<Pick<BoardItem, 'rank' | 'needs' | 'open_blockers'>> & { body?: string };

/**
 * Only the GitHub adapter computes rank, needs and open_blockers, so an item without them gets
 * the board's sort default, no needs, and the blockers that are open items on this board.
 */
export function parseBoard(source: string): BoardFacts {
  const parsed = JSON.parse(source) as { items?: unknown };
  const items = Array.isArray(parsed.items) ? (parsed.items as AdapterItem[]) : [];
  const open = new Set(items.filter((item) => item.status === 'open').map((item) => item.id));
  return {
    items: items.map(({ body: _body, rank, needs, open_blockers, ...item }) => ({
      ...item,
      rank: rank ?? UNRANKED,
      needs: needs ?? [],
      open_blockers: open_blockers ?? item.blocked_by.filter((id) => open.has(id)),
    })),
  };
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
