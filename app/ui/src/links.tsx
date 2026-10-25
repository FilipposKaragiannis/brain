import type { ReactNode } from 'react';
import type { Snapshot } from '../../daemon/src/snapshot.ts';

/** Where the console looks an item's tracker page up: the board's items, then the worktrees that claim it. */
export type ItemPages = Pick<Snapshot, 'items' | 'worktrees'>;

/** An item's tracker page: the board's URL for it, else the `itemUrl` of a worktree that claims it. */
export function trackerUrl(pages: ItemPages, id: string): string | null {
  const fromBoard = pages.items.find((item) => item.id === id)?.url ?? null;
  if (fromBoard !== null) return fromBoard;
  return pages.worktrees.find((worktree) => worktree.item === id && worktree.itemUrl !== null)?.itemUrl ?? null;
}

const SAFE_SCHEMES = new Set(['http:', 'https:']);

/** The URL when it is an absolute http or https address, else null: a tracker may hand back anything, `javascript:` included. */
export function safeHref(url: string | null): string | null {
  if (url === null) return null;
  try {
    return SAFE_SCHEMES.has(new URL(url).protocol) ? url : null;
  } catch {
    return null;
  }
}

/** A link out of the console, in a new tab, for a URL that came from the snapshot; plain text when the URL is not a safe web address. */
export function ExternalLink({ url, className, children }: { url: string | null; className: string; children: ReactNode }) {
  const href = safeHref(url);
  if (href === null) return <span className={className}>{children}</span>;
  return <a className={className} href={href} target="_blank" rel="noreferrer">{children}</a>;
}

/** An item id that opens its tracker page in a new tab, or plain text when no safe page is known. */
export function ItemLink({ id, pages }: { id: string; pages: ItemPages }) {
  return <ExternalLink url={trackerUrl(pages, id)} className="mono item-link">{id}</ExternalLink>;
}
