import { useState } from 'react';
import type { AttentionRow, Snapshot } from '../../../daemon/src/snapshot.ts';
import { Age } from '../clock.tsx';
import { ItemLink } from '../links.tsx';
import type { Route } from '../route.ts';
import { attentionTone } from '../status.ts';
import { Chip, Empty, Module, SourceFreshness } from '../ui.tsx';

/** How many items that wait on a field show before "Show all"; there can be hundreds. */
export const FIELD_ROWS_SHOWN = 5;
const COLUMNS = 6;

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
  return (
    <Module className="needs-you" title="Needs you" aside={<span className="muted">oldest first</span>} footer={<><SourceFreshness name="files" freshness={snapshot.sources.files} /><SourceFreshness name="board" freshness={snapshot.sources.board} /></>}>
      {sorted.length === 0 ? <Empty>Nothing waits on you.</Empty> : (
        <div className="scroll">
          <table className="table">
            <thead><tr><th>Kind</th><th>Item</th><th>Title</th><th>Detail</th><th>Worktree</th><th>Age</th></tr></thead>
            <tbody>
              {[...others, ...shownFields].map((row) => <AttentionLine key={`${row.kind}:${row.id}:${row.worktree ?? ''}`} row={row} snapshot={snapshot} go={go} />)}
              {fieldRows.length > FIELD_ROWS_SHOWN && (
                <tr>
                  <td colSpan={COLUMNS}>
                    <button type="button" className="row-link" onClick={() => setAllFields((shown) => !shown)}>
                      {allFields ? 'Show fewer next-in-line items that lack a field' : `Show all ${fieldRows.length} next-in-line items that lack a field`}
                    </button>
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      )}
    </Module>
  );
}

function AttentionLine({ row, snapshot, go }: { row: AttentionRow; snapshot: Snapshot; go: (route: Route) => void }) {
  const destination = rowTarget(row, snapshot.project.id);
  return (
    <tr>
      <td><Chip tone={attentionTone(row.kind)}>{row.kind}</Chip></td>
      <td><ItemLink id={row.id} pages={snapshot} /></td>
      <td className="strong clip" title={row.title}>{destination === null ? row.title : <button type="button" className="row-link" onClick={() => go(destination)}>{row.title}</button>}</td>
      <td className="clip" title={row.detail}>{row.detail}</td>
      <td className="mono">{row.worktree ?? '—'}</td>
      <td className="mono"><Age seconds={row.ageSeconds} takenAt={snapshot.takenAt} /></td>
    </tr>
  );
}

function rowTarget(row: AttentionRow, projectId: string): Route | null {
  if (row.kind === 'gate') return { projectId, screen: 'gates', detail: row.id };
  if (row.kind.startsWith('pr-')) return { projectId, screen: 'pulls', detail: null };
  if (row.worktree !== null) return { projectId, screen: 'worktrees', detail: null };
  return null;
}

function oldestFirst(left: AttentionRow, right: AttentionRow): number {
  return (right.ageSeconds ?? -1) - (left.ageSeconds ?? -1);
}
