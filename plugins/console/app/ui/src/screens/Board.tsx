import { useState } from 'react';
import type { Item, ItemState, Snapshot } from '../../../daemon/src/snapshot.ts';
import { ExternalLink, ItemLink } from '../links.tsx';
import { isParked, ParkedLine } from '../parked.tsx';
import { PULL_STATE_LABEL, namesSaid, pullLabel, pullUrl } from '../pulls.ts';
import { routeHash } from '../route.ts';
import { formatCost, formatTokens, spendCell, spendTotal } from '../spend.ts';
import { itemTone } from '../status.ts';
import { WORDS } from '../words.ts';
import { Chip, Empty, Module, SourceFreshness } from '../ui.tsx';

/** The board's filters: each names the item states it keeps. */
const FILTERS: Array<{ label: string; states: ItemState[] }> = [
  { label: 'All open', states: ['needs-you', 'running', 'stale', 'waiting', 'held', 'claimed', 'in-review', 'ready', 'blocked', 'backlog'] },
  { label: 'Under way', states: ['needs-you', 'running', 'stale', 'claimed'] },
  { label: 'Waiting', states: ['waiting', 'held'] },
  { label: 'In review', states: ['in-review'] },
  { label: 'Ready', states: ['ready'] },
  { label: 'Blocked', states: ['blocked'] },
  { label: 'Backlog', states: ['backlog'] },
];

/** The words an item state shows in, where the state's own name is not plain enough. */
const STATE_LABEL: Partial<Record<ItemState, string>> = { 'needs-you': 'needs you', 'in-review': 'in review' };

/**
 * The open items from the board, in the snapshot's order (what needs you first, then by rank),
 * each with what its sessions cost. The head line sums the spend of the items the filter shows;
 * an item picked by its title shows its detail beside the list, sessions and tokens included.
 * A tracker the board could not read says so above the list, with why, since its items are missing.
 */
export function Board({ snapshot, selected }: { snapshot: Snapshot; selected: string | null }) {
  const [filter, setFilter] = useState(FILTERS[0]?.label ?? '');
  const open = snapshot.items.filter((item) => item.status === 'open');
  const states = FILTERS.find((entry) => entry.label === filter)?.states ?? [];
  const shown = open.filter((item) => states.includes(item.state));
  const picked = selected === null ? null : snapshot.items.find((item) => item.id === selected) ?? null;
  const total = spendTotal(shown);
  const unread = snapshot.project.trackers.filter((tracker) => tracker.error !== null);
  return (
    <div className="screen">
      {unread.map((tracker) => <p key={tracker.name} className="banner tone-failing" role="alert">{trackerNotRead(tracker.name, tracker.error ?? '')}</p>)}
      <div className="board-head">
        <div className="board-filters" role="group" aria-label="Filter">
          {FILTERS.map((entry) => {
            const count = open.filter((item) => entry.states.includes(item.state)).length;
            return <button key={entry.label} type="button" className={entry.label === filter ? 'button active' : 'button'} aria-pressed={entry.label === filter} onClick={() => setFilter(entry.label)}>{entry.label} <span className="muted">{count}</span></button>;
          })}
        </div>
        <p className="board-total" aria-label="Spend shown">
          {total.items === 0 ? 'No spend recorded for these items.' : <>{formatCost(total.costUsd)} on {counted(total.items, 'item')} · {counted(total.sessions, 'session')} · {formatTokens(total.tokens)} tokens</>}
        </p>
      </div>
      <div className="columns">
        <Module className="board" title="Items" aside={<span className="muted">{shown.length} of {open.length} open</span>} footer={<SourceFreshness name="board" freshness={snapshot.sources.board} />}>
          {shown.length === 0 ? <Empty>No open item here.</Empty> : <ItemTable items={shown} snapshot={snapshot} selected={picked?.id ?? null} />}
        </Module>
        {picked !== null && <ItemDetail item={picked} snapshot={snapshot} />}
      </div>
    </div>
  );
}

/** The banner for a tracker the board could not read: its items are not on the board, and why. */
export function trackerNotRead(tracker: string, error: string): string {
  return `The ${tracker} items are not on the board: ${error}`;
}

/** `1 item`, `3 items`. */
function counted(count: number, noun: string): string {
  return `${count} ${noun}${count === 1 ? '' : 's'}`;
}

function ItemTable({ items, snapshot, selected }: { items: Item[]; snapshot: Snapshot; selected: string | null }) {
  return (
    <div className="scroll">
      <table className="table board-table">
        <thead><tr><th>Item</th><th>Title</th><th>State</th><th>Step</th><th>Worktree</th><th>PR</th><th className="number">Spend</th></tr></thead>
        <tbody>
          {items.map((item) => (
            <tr key={item.id} className={item.id === selected ? 'selected' : undefined}>
              <td><ItemLink id={item.id} pages={snapshot} /></td>
              <td className="clip strong"><a href={routeHash({ projectId: snapshot.project.id, screen: 'board', detail: item.id })} title={item.title} aria-current={item.id === selected ? 'true' : undefined}>{item.title || item.id}</a></td>
              <td><StateCell item={item} snapshot={snapshot} /></td>
              <td className="mono"><StepCell item={item} /></td>
              <td className="mono">{item.worktree ?? '—'}</td>
              <td><PullCell item={item} snapshot={snapshot} /></td>
              <td className="mono number" title={item.spend === null ? undefined : `${item.spend.sessions} sessions · ${item.spend.tokens} tokens`}>{spendCell(item.spend)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** The state chip; a held item names what it waits behind, linked, with why on hover. */
function StateCell({ item, snapshot }: { item: Item; snapshot: Snapshot }) {
  const chip = <Chip tone={itemTone(item.state)}>{STATE_LABEL[item.state] ?? item.state}</Chip>;
  if (item.state !== 'held' || item.heldBy === null) return item.state === 'waiting' ? <span title={WORDS.waiting}>{chip}</span> : chip;
  return <span className="held-cell" title={item.heldReason ?? WORDS.held}>{chip} <span className="muted">behind</span> <ItemLink id={item.heldBy} pages={snapshot} /></span>;
}

/** The step: the live one, or for parked work the one it runs next, said as such so it never reads as work going on. */
function StepCell({ item }: { item: Item }) {
  if (item.step === '') return <>—</>;
  return isParked(item.state) ? <span className="muted" title={WORDS.waiting}>next: {item.step}</span> : <>{item.step}</>;
}

/** The item's open PR as the pulls source matched it (by its `pr` field or its claimed branch), else the item's own `pr` field. */
function PullCell({ item, snapshot }: { item: Item; snapshot: Snapshot }) {
  const pull = snapshot.pulls.find((entry) => entry.item === item.id) ?? null;
  if (pull !== null) return <ExternalLink url={pull.url} className="mono">#{pull.number}</ExternalLink>;
  return item.pr === null ? <>—</> : <ExternalLink url={pullUrl(item.pr, snapshot.project.repo)} className="mono">{pullLabel(item.pr)}</ExternalLink>;
}

/** One item: its fields, its pull and where its review stands, and what its sessions cost. */
function ItemDetail({ item, snapshot }: { item: Item; snapshot: Snapshot }) {
  const pull = snapshot.pulls.find((entry) => entry.item === item.id) ?? null;
  const close = routeHash({ projectId: snapshot.project.id, screen: 'board', detail: null });
  const parked = isParked(item.state);
  const facts: Array<[string, string]> = [
    ['Kind', [item.kind, item.size, item.priority].filter((part) => part !== '').join(' · ') || '—'],
    [parked ? 'Next step' : 'Step', item.step || '—'],
    ['Gate', item.gate === 'none' || item.gate === '' ? '—' : item.gate],
    ['Worktree', item.worktree ?? '—'],
    ['Parent', item.parent ?? '—'],
    ['Blocked by', item.openBlockers.length === 0 ? '—' : item.openBlockers.join(', ')],
    ['Needs', item.needs.length === 0 ? '—' : item.needs.join(', ')],
  ];
  return (
    <Module className="item-detail" title={<><ItemLink id={item.id} pages={snapshot} /><span className="clip">{item.title}</span></>} aside={<a href={close} aria-label="Close">Close</a>} footer={<SourceFreshness name="board" freshness={snapshot.sources.board} />}>
      <div className="item-detail-body">
        <Chip tone={itemTone(item.state)}>{STATE_LABEL[item.state] ?? item.state}</Chip>
        {(parked || item.heldBy !== null) && (
          <p className="parked-line" aria-label="Waits for">
            <ParkedLine heldBy={item.heldBy} step={item.step} pages={snapshot} />{item.heldReason !== null && <span className="muted">: {item.heldReason}</span>}
          </p>
        )}
        <dl className="item-facts">
          {facts.map(([label, value]) => <div key={label}><dt>{label}</dt><dd>{value}</dd></div>)}
          {pull !== null && (
            <div><dt>Pull request</dt><dd><ExternalLink url={pull.url} className="mono">#{pull.number}</ExternalLink> {PULL_STATE_LABEL[pull.state]}{pull.state === 'in-review' && pull.review !== null ? `, waiting on ${namesSaid(pull.review.waiting)}` : ''}</dd></div>
          )}
        </dl>
        <h3 className="group-head">Spend</h3>
        {item.spend === null ? <p className="muted">No step session recorded for this item.</p> : (
          <dl className="item-facts" aria-label="Spend">
            <div><dt>Cost</dt><dd>{item.spend.costUsd > 0 ? formatCost(item.spend.costUsd) : 'not reported by the host'}</dd></div>
            <div><dt>Sessions</dt><dd>{item.spend.sessions}</dd></div>
            <div><dt>Tokens</dt><dd>{item.spend.tokens.toLocaleString('en-US')}</dd></div>
          </dl>
        )}
      </div>
    </Module>
  );
}
