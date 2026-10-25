import type { PullRequest, Snapshot } from '../../../daemon/src/snapshot.ts';
import { Age } from '../clock.tsx';
import { ItemLink } from '../links.tsx';
import type { ItemPages } from '../links.tsx';
import { pullRowsFromItems } from '../pulls.ts';
import type { PullRequestRow } from '../pulls.ts';
import { itemTone, pullTone } from '../status.ts';
import { ActionButton, Chip, Empty, Module, SourceFreshness } from '../ui.tsx';

/**
 * Open pull requests from the daemon's `pulls` source. Until that source has been read once, or
 * on a project it does not apply to, the items that carry a PR stand in.
 */
export function Pulls({ snapshot }: { snapshot: Snapshot }) {
  const pullsRead = snapshot.sources.pulls.at !== null && snapshot.sources.pulls.error === null;
  const aside = <span className="muted">{pullsRead ? snapshot.pulls.length : pullRowsFromItems(snapshot.items, snapshot.project.repo).length} open</span>;
  return (
    <div className="screen">
      <Module className="pulls" title="Pull requests" aside={aside} footer={<SourceFreshness name="pulls" freshness={snapshot.sources.pulls} />}>
        {pullsRead ? <PullTable pulls={snapshot.pulls} takenAt={snapshot.takenAt} pages={snapshot} /> : <PullRequestTable rows={pullRowsFromItems(snapshot.items, snapshot.project.repo)} pages={snapshot} />}
      </Module>
    </div>
  );
}

function PullTable({ pulls, takenAt, pages }: { pulls: PullRequest[]; takenAt: string; pages: ItemPages }) {
  if (pulls.length === 0) return <Empty>No open pull request.</Empty>;
  return (
    <div className="scroll">
      <table className="table">
        <thead><tr><th>PR</th><th>Title</th><th>State</th><th>Checks</th><th>Threads</th><th>Item</th><th>Worktree</th><th>Idle</th><th /></tr></thead>
        <tbody>
          {pulls.map((pull) => (
            <tr key={pull.number}>
              <td className="mono"><a href={pull.url} target="_blank" rel="noreferrer">#{pull.number}</a></td>
              <td className="strong clip" title={pull.title}>{pull.title}</td>
              <td><Chip tone={pullTone(pull.state)}>{pull.state}</Chip></td>
              <td className="mono" title="passed / failed / pending">{pull.checks.passed} / {pull.checks.failed} / {pull.checks.pending}</td>
              <td className="mono">{pull.unresolvedThreads}</td>
              <td>{pull.item === null ? '—' : <ItemLink id={pull.item} pages={pages} />}</td>
              <td className="mono">{pull.worktree ?? '—'}</td>
              <td className="mono"><Age seconds={pull.idleSeconds} takenAt={takenAt} /></td>
              <td>{pull.state === 'mergeable' && <ActionButton kind="pr.merge" args={{ pr: String(pull.number) }} label="Merge" primary={true} />}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/** The fallback table from items; it renders any list of rows, whichever source built them. */
export function PullRequestTable({ rows, pages }: { rows: PullRequestRow[]; pages: ItemPages }) {
  if (rows.length === 0) return <Empty>No item has a pull request.</Empty>;
  return (
    <table className="table">
      <thead><tr><th>Item</th><th>Title</th><th>PR</th><th>State</th><th>Worktree</th></tr></thead>
      <tbody>
        {rows.map((row) => (
          <tr key={`${row.item}:${row.pr}`}>
            <td><ItemLink id={row.item} pages={pages} /></td>
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
