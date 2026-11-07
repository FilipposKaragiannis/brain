import path from 'node:path';
import type { CommandRunner } from './exec.ts';
import { JIRA_TOKEN, scriptEnvironment } from './exec.ts';

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
  /**
   * The item's flow state. `held_by` is the item this one waits behind (flow's ready filter skips it
   * until that one closes) and `held_reason` one line on why: empty when the item is free, absent on
   * a plugin from before the hold keys (flow 1.33.0 and earlier).
   */
  state: { step: string; gate: string; worktree: string; pr: string; last_event: string; profile: string; attempts: number; held_by?: string; held_reason?: string };
};

/** One item's spend from `board.sh --json`: the step sessions in flow's runs.jsonl, summed. */
export type BoardSpend = { cost_usd: number; sessions: number; tokens: number };

/**
 * A tracker the board could not read: `tracker_errors` of `board.sh --json`, the adapter's exit
 * code and its last stderr line, or one the console tells before a script runs (code null).
 */
export type TrackerError = { tracker: string; code: number | null; message: string };

/**
 * The items, each item's body by id (kept apart so only the screens that show a body carry one),
 * each item's spend by id, empty on a plugin before flow 1.22.0, and the trackers that could not
 * be read, whose items are missing.
 */
export type BoardFacts = { items: BoardItem[]; bodies: Record<string, string>; spend: Record<string, BoardSpend>; trackerErrors: TrackerError[] };

/** The tracker that reads its token from the console's environment, and the variable. */
const JIRA_ADAPTER = 'jira';

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
  const parsed = JSON.parse(source) as { items?: unknown; spend?: unknown; tracker_errors?: unknown };
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
    trackerErrors: parseTrackerErrors(parsed.tracker_errors),
  };
}

/** `tracker_errors`, keeping the entries that name a tracker; absent before the plugin reported them. */
function parseTrackerErrors(value: unknown): TrackerError[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((entry: unknown) => {
    const error = entry as Partial<TrackerError> | null;
    if (error === null || typeof error !== 'object' || typeof error.tracker !== 'string') return [];
    return [{ tracker: error.tracker, code: typeof error.code === 'number' ? error.code : null, message: typeof error.message === 'string' ? error.message : '' }];
  });
}

/**
 * The trackers the board reports, with the one the console can name itself: jira read without
 * JIRA_API_TOKEN in the daemon's environment, which no flow script can pass on. It stands in for
 * the adapter's own error, and also shows on a plugin too old to report one.
 */
export function withConsoleTrackerErrors(reported: TrackerError[], trackers: string[], env: Record<string, string>): TrackerError[] {
  if (!trackers.includes(JIRA_ADAPTER) || (env[JIRA_TOKEN] ?? '') !== '') return reported;
  const missing: TrackerError = {
    tracker: JIRA_ADAPTER, code: null,
    message: `${JIRA_TOKEN} is not set in the console's environment, so the Jira items cannot be read: export it in the shell that starts brain-console (for the launch agent, run brain-console install again from that shell) and restart the console`,
  };
  return [missing, ...reported.filter((error) => error.tracker !== JIRA_ADAPTER)];
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

/** `board.sh --json` in the project, with the trackers it read (`trackers` of the config) checked for a token the console lacks. */
export async function readBoard(root: string, pluginRoot: string, runner: CommandRunner, trackers: string[]): Promise<BoardFacts> {
  const env = scriptEnvironment();
  const result = await runner({
    command: 'sh',
    args: [path.join(pluginRoot, 'scripts', 'board.sh'), '--json'],
    cwd: root,
    timeoutMs: BOARD_TIMEOUT_MS,
    env,
  });
  if (result.code !== 0) throw new Error(`board.sh --json failed: ${result.stderr.trim() || result.code}`);
  const board = parseBoard(result.stdout);
  return { ...board, trackerErrors: withConsoleTrackerErrors(board.trackerErrors, trackers, env) };
}
