import type { Item, ItemSpend } from '../../daemon/src/snapshot.ts';

const CENT = 0.01;
const THOUSAND = 1000;
const MILLION = 1000000;

/** A cost in dollars as a cell shows it: two decimals, and under a cent said so, never `$0.00`. */
export function formatCost(usd: number): string {
  return usd > 0 && usd < CENT ? '<$0.01' : `$${usd.toFixed(2)}`;
}

/** A token count in a few characters: 950, 120k, 1.2M. */
export function formatTokens(tokens: number): string {
  if (tokens >= MILLION) return `${trim(tokens / MILLION)}M`;
  if (tokens >= THOUSAND) return `${trim(tokens / THOUSAND)}k`;
  return String(tokens);
}

function trim(value: number): string {
  return value >= 100 ? value.toFixed(0) : value.toFixed(1).replace(/\.0$/, '');
}

/** What the cost cell says: the cost a host reported, else the tokens, since codex reports no cost; nothing without spend. */
export function spendCell(spend: ItemSpend | null): string {
  if (spend === null) return '';
  return spend.costUsd > 0 ? formatCost(spend.costUsd) : `${formatTokens(spend.tokens)} tokens`;
}

/** The spend of the items given, summed: what the board's head line says for the items on screen. */
export function spendTotal(items: readonly Item[]): ItemSpend & { items: number } {
  const spent = items.flatMap((item) => (item.spend === null ? [] : [item.spend]));
  return {
    costUsd: spent.reduce((sum, spend) => sum + spend.costUsd, 0),
    sessions: spent.reduce((sum, spend) => sum + spend.sessions, 0),
    tokens: spent.reduce((sum, spend) => sum + spend.tokens, 0),
    items: spent.length,
  };
}
