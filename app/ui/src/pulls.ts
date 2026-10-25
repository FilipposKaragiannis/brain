import type { Item, ItemState } from '../../daemon/src/snapshot.ts';

/** One row of the pull request table, whatever the source of the list. */
export type PullRequestRow = { item: string; title: string; pr: string; url: string | null; state: ItemState; worktree: string | null };

const PR_NUMBER = /(\d+)\s*$/;

/** Rows from the items that carry a PR. The snapshot's own pull request list will replace this source. */
export function pullRowsFromItems(items: Item[], repo: string | null): PullRequestRow[] {
  return items.filter((item) => item.pr !== null && item.pr !== '').map((item) => ({
    item: item.id,
    title: item.title,
    pr: pullLabel(item.pr ?? ''),
    url: pullUrl(item.pr ?? '', repo),
    state: item.state,
    worktree: item.worktree,
  }));
}

export function pullLabel(pr: string): string {
  const number = PR_NUMBER.exec(pr.replace(/\/+$/, ''))?.[1];
  return number === undefined ? pr : `#${number}`;
}

export function pullUrl(pr: string, repo: string | null): string | null {
  if (/^https?:\/\//.test(pr)) return pr;
  const number = PR_NUMBER.exec(pr)?.[1];
  if (number === undefined || repo === null) return null;
  return `https://github.com/${repo}/pull/${number}`;
}
