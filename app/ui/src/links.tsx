import type { Snapshot } from '../../daemon/src/snapshot.ts';

/** Where the console looks an item's tracker page up: the board's items, then the worktrees that claim it. */
export type ItemPages = Pick<Snapshot, 'items' | 'worktrees'>;

/** An item's tracker page: the board's URL for it, else the `itemUrl` of a worktree that claims it. */
export function trackerUrl(pages: ItemPages, id: string): string | null {
  const fromBoard = pages.items.find((item) => item.id === id)?.url ?? null;
  if (fromBoard !== null) return fromBoard;
  return pages.worktrees.find((worktree) => worktree.item === id && worktree.itemUrl !== null)?.itemUrl ?? null;
}

/** An item id that opens its tracker page in a new tab, or plain text when no page is known. */
export function ItemLink({ id, pages }: { id: string; pages: ItemPages }) {
  const url = trackerUrl(pages, id);
  if (url === null) return <span className="mono">{id}</span>;
  return <a className="mono item-link" href={url} target="_blank" rel="noreferrer" title={`Open ${id} in the tracker`}>{id}</a>;
}
