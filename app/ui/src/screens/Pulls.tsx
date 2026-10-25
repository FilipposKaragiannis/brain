import type { Snapshot } from '../../../daemon/src/snapshot.ts';
import { pullRowsFromItems } from '../pulls.ts';
import type { PullRequestRow } from '../pulls.ts';
import { itemTone } from '../status.ts';
import { Chip, Empty, Module, SourceFreshness } from '../ui.tsx';

export function Pulls({ snapshot }: { snapshot: Snapshot }) {
  const rows = pullRowsFromItems(snapshot.items, snapshot.project.repo);
  return (
    <div className="screen">
      <Module className="pulls" title="Pull requests" aside={<span className="muted">{rows.length} open</span>} footer={<SourceFreshness name="board" freshness={snapshot.sources.board} />}>
        <PullRequestTable rows={rows} />
      </Module>
    </div>
  );
}

/** The pull request table; it renders any list of rows, whichever source built them. */
export function PullRequestTable({ rows }: { rows: PullRequestRow[] }) {
  if (rows.length === 0) return <Empty>No item has a pull request.</Empty>;
  return (
    <table className="table">
      <thead><tr><th>Item</th><th>Title</th><th>PR</th><th>State</th><th>Worktree</th></tr></thead>
      <tbody>
        {rows.map((row) => (
          <tr key={`${row.item}:${row.pr}`}>
            <td className="mono">{row.item}</td>
            <td className="strong">{row.title}</td>
            <td className="mono">{row.url === null ? row.pr : <a href={row.url} target="_blank" rel="noreferrer">{row.pr}</a>}</td>
            <td><Chip tone={itemTone(row.state)}>{row.state}</Chip></td>
            <td className="mono">{row.worktree ?? '—'}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
