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

export function parseBoard(source: string): BoardFacts {
  const parsed = JSON.parse(source) as { items?: unknown };
  const items = Array.isArray(parsed.items) ? (parsed.items as (BoardItem & { body?: string })[]) : [];
  return { items: items.map(({ body: _body, ...item }) => item) };
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
