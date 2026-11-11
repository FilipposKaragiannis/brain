import { useState } from 'react';
import type { AttentionKind, AttentionRow, Snapshot } from '../../../daemon/src/snapshot.ts';
import { Age } from '../clock.tsx';
import { ExternalLink, ItemLink, trackerUrl } from '../links.tsx';
import type { Route } from '../route.ts';
import { routeHash } from '../route.ts';
import { attentionTone } from '../status.ts';
import { ActionButton, Chip, Empty, Module, SourceFreshness } from '../ui.tsx';

/** How many items that wait on a field show before "Show all"; there can be hundreds. */
export const FIELD_ROWS_SHOWN = 5;
const SECONDS_PER_HOUR = 3600;
const LATE_HOURS = 24;
const OLD_HOURS = 48;
const FULL_BAR_HOURS = 72;

/** The word on a row's button, which opens the screen where the row is settled. */
const VERBS: Record<AttentionKind, string> = {
  'gate': 'Decide', 'close': 'Decide', 'label-gate': 'Open', 'dead-run': 'Open', 'stale': 'Fix', 'disagreement': 'Open', 'job-failed': 'Open',
  'pr-failing': 'Open PR', 'pr-changes-requested': 'Open PR', 'pr-mergeable': 'Open PR', 'needs-field': 'Fill in', 'host-stopped': 'Open',
};

/**
 * What needs a human, oldest first. Items that wait only on an empty field come last and fold
 * after a few, so a backlog with no priorities does not bury the gates.
 */
export function NeedsYou({ snapshot, go }: { snapshot: Snapshot; go: (route: Route) => void }) {
  const [allFields, setAllFields] = useState(false);
  const sorted = [...snapshot.attention].sort(oldestFirst);
  const others = sorted.filter((row) => row.kind !== 'needs-field');
  const fieldRows = sorted.filter((row) => row.kind === 'needs-field');
  const shownFields = allFields ? fieldRows : fieldRows.slice(0, FIELD_ROWS_SHOWN);
  const gates = routeHash({ projectId: snapshot.project.id, screen: 'gates', detail: null });
  return (
    <Module className="needs-you" title={<>Needs you <span className="muted">oldest first</span></>} aside={<a className="module-link" href={gates}>All gates</a>} footer={<><SourceFreshness name="files" freshness={snapshot.sources.files} /><SourceFreshness name="board" freshness={snapshot.sources.board} /></>}>
      {sorted.length === 0 ? <Empty>Nothing waits on you.</Empty> : (
        <ul className="attention-list">
          {[...others, ...shownFields].map((row) => <AttentionLine key={`${row.kind}:${row.id}:${row.worktree ?? ''}`} row={row} snapshot={snapshot} go={go} />)}
          {fieldRows.length > FIELD_ROWS_SHOWN && (
            <li className="attention-more">
              <button type="button" className="row-link" onClick={() => setAllFields((shown) => !shown)}>
                {allFields ? 'Show fewer next-in-line items that lack a field' : `Show all ${fieldRows.length} next-in-line items that lack a field`}
              </button>
            </li>
          )}
        </ul>
      )}
    </Module>
  );
}

/** One row: its kind (a gate's own kind on a gate row), the item and title over what it waits on, how long it has waited, and the one button that settles it. */
function AttentionLine({ row, snapshot, go }: { row: AttentionRow; snapshot: Snapshot; go: (route: Route) => void }) {
  const destination = rowTarget(row, snapshot.project.id);
  const { tone, percent } = lateness(row.ageSeconds);
  const meta = [row.detail, row.worktree].filter((part) => part !== null && part !== '').join(' · ');
  return (
    <li className="attention-row">
      <Chip tone={attentionTone(row.kind)}>{row.gate ?? row.kind}</Chip>
      <div className="attention-what">
        <div className="attention-line">
          <ItemLink id={row.id} pages={snapshot} />
          <span className="strong clip-line" title={row.title}>{destination === null ? row.title : <button type="button" className="row-link" onClick={() => go(destination)}>{row.title}</button>}</span>
        </div>
        <div className="attention-meta" title={meta}>{meta}</div>
      </div>
      <div className="attention-age">
        <span className="attention-age-line"><span className="muted">waiting</span><span className={`gate-age ${tone}`}><Age seconds={row.ageSeconds} takenAt={snapshot.takenAt} /></span></span>
        <span className="age-bar"><span className={tone} style={{ width: `${percent}%` }} /></span>
      </div>
      <div className="attention-act">
        {row.action !== null
          ? <ActionButton kind={row.action.kind} args={row.action.args} label={row.action.label} primary />
          : <RowButton row={row} snapshot={snapshot} destination={destination} go={go} />}
      </div>
    </li>
  );
}

/** The row's way to the screen that settles it; an item that waits on a field opens its tracker page instead. */
function RowButton({ row, snapshot, destination, go }: { row: AttentionRow; snapshot: Snapshot; destination: Route | null; go: (route: Route) => void }) {
  if (destination !== null) return <button type="button" className="button primary" onClick={() => go(destination)}>{VERBS[row.kind]}</button>;
  const url = trackerUrl(snapshot, row.id);
  if (row.kind !== 'needs-field' || url === null) return null;
  return <ExternalLink url={url} className="button primary">{VERBS[row.kind]}</ExternalLink>;
}

/** How late a row is: a tone for its age and how full its age bar is, as the gate list shows them. */
function lateness(ageSeconds: number | null): { tone: 'fresh' | 'late' | 'old'; percent: number } {
  const hours = (ageSeconds ?? 0) / SECONDS_PER_HOUR;
  const tone = hours >= OLD_HOURS ? 'old' : hours >= LATE_HOURS ? 'late' : 'fresh';
  return { tone, percent: Math.min(hours / FULL_BAR_HOURS, 1) * 100 };
}

function rowTarget(row: AttentionRow, projectId: string): Route | null {
  if (row.kind === 'gate' || row.kind === 'close' || row.kind === 'label-gate') return { projectId, screen: 'gates', detail: row.id };
  if (row.kind.startsWith('pr-')) return { projectId, screen: 'pulls', detail: null };
  if (row.kind === 'host-stopped' || row.kind === 'job-failed') return { projectId, screen: 'jobs', detail: null };
  if (row.worktree !== null) return { projectId, screen: 'worktrees', detail: null };
  return null;
}

function oldestFirst(left: AttentionRow, right: AttentionRow): number {
  return (right.ageSeconds ?? -1) - (left.ageSeconds ?? -1);
}
