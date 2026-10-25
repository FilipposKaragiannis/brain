import type { AttentionRow, Snapshot, SourceName, Worktree } from '../../../daemon/src/snapshot.ts';
import { Age, clockTime } from '../clock.tsx';
import type { Route } from '../route.ts';
import { routeHash } from '../route.ts';
import { attentionTone, countTone, worktreeTone } from '../status.ts';
import type { Tone } from '../status.ts';
import { Chip, Dot, Empty, Flags, Module, SourceFreshness } from '../ui.tsx';

const EVENTS_SHOWN = 30;
const SOURCE_NAMES: SourceName[] = ['files', 'git', 'processes', 'jobs', 'board'];

type Tile = { label: string; count: number; tone: Tone; screen: Route['screen'] };

export function Overview({ snapshot, go }: { snapshot: Snapshot; go: (route: Route) => void }) {
  const projectId = snapshot.project.id;
  const counts = snapshot.counts;
  const tiles: Tile[] = [
    { label: 'Needs you', count: counts.needsYou, tone: countTone(counts.needsYou, 'needs-you'), screen: 'gates' },
    { label: 'Running', count: counts.running, tone: countTone(counts.running, 'running'), screen: 'agents' },
    { label: 'Stale', count: counts.stale, tone: countTone(counts.stale, 'stale'), screen: 'worktrees' },
    { label: 'Free', count: counts.free, tone: 'quiet', screen: 'worktrees' },
    { label: 'Disagreements', count: counts.disagreements, tone: countTone(counts.disagreements, 'failing'), screen: 'overview' },
  ];
  const openRow = (row: AttentionRow): void => {
    if (row.kind === 'gate') go({ projectId, screen: 'gates', detail: row.id });
    else if (row.worktree !== null) go({ projectId, screen: 'worktrees', detail: null });
  };
  return (
    <div className="screen">
      <section className="tiles" aria-label="Status">
        {tiles.map((tile) => (
          <a key={tile.label} className={`tile tone-${tile.tone}`} href={routeHash({ projectId, screen: tile.screen, detail: null })}>
            <span className="tile-label">{tile.label}<Dot tone={tile.tone} /></span>
            <span className="tile-count">{tile.count}</span>
          </a>
        ))}
      </section>
      <div className="columns">
        <NeedsYou snapshot={snapshot} open={openRow} />
        <Events snapshot={snapshot} />
      </div>
      <Pool snapshot={snapshot} />
      <Module className="sources" title="Sources" aside={null} footer={<span>taken at {clockTime(snapshot.takenAt)} · <Age seconds={0} takenAt={snapshot.takenAt} /> ago</span>}>
        <ul className="source-strip">
          {SOURCE_NAMES.map((name) => <li key={name}><SourceFreshness name={name} freshness={snapshot.sources[name]} /></li>)}
        </ul>
      </Module>
    </div>
  );
}

function NeedsYou({ snapshot, open }: { snapshot: Snapshot; open: (row: AttentionRow) => void }) {
  const rows = [...snapshot.attention].sort(oldestFirst);
  return (
    <Module className="needs-you" title="Needs you" aside={<span className="muted">oldest first</span>} footer={<SourceFreshness name="files" freshness={snapshot.sources.files} />}>
      {rows.length === 0 ? <Empty>Nothing waits on you.</Empty> : (
        <table className="table clickable">
          <thead><tr><th>Kind</th><th>Item</th><th>Title</th><th>Detail</th><th>Worktree</th><th>Age</th></tr></thead>
          <tbody>
            {rows.map((row) => (
              <tr key={`${row.kind}:${row.id}:${row.worktree ?? ''}`} onClick={() => open(row)} tabIndex={0} onKeyDown={(event) => { if (event.key === 'Enter') open(row); }}>
                <td><Chip tone={attentionTone(row.kind)}>{row.kind}</Chip></td>
                <td className="mono">{row.id}</td>
                <td className="strong">{row.title}</td>
                <td className="clip" title={row.detail}>{row.detail}</td>
                <td className="mono">{row.worktree ?? '—'}</td>
                <td className="mono"><Age seconds={row.ageSeconds} takenAt={snapshot.takenAt} /></td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </Module>
  );
}

function oldestFirst(left: AttentionRow, right: AttentionRow): number {
  return (right.ageSeconds ?? -1) - (left.ageSeconds ?? -1);
}

function Pool({ snapshot }: { snapshot: Snapshot }) {
  const pool = snapshot.worktrees.filter((worktree) => worktree.role === 'pool');
  const max = snapshot.project.poolMax;
  return (
    <Module className="pool" title="Pool" aside={<span className="muted">{pool.length}{max === null ? '' : ` of ${max}`} · base {snapshot.project.base}</span>} footer={<SourceFreshness name="git" freshness={snapshot.sources.git} />}>
      {pool.length === 0 ? <Empty>No pool worktrees.</Empty> : (
        <div className="pool-map">{pool.map((worktree) => <PoolCell key={worktree.name} worktree={worktree} takenAt={snapshot.takenAt} />)}</div>
      )}
    </Module>
  );
}

function PoolCell({ worktree, takenAt }: { worktree: Worktree; takenAt: string }) {
  const tone = worktreeTone(worktree.state);
  return (
    <div className={`pool-cell tone-${tone}`} title={`${worktree.name}: ${worktree.state}`}>
      <span className="pool-name"><span className="mono">{worktree.name}</span><Dot tone={tone} /></span>
      <span className="pool-item">{worktree.item ?? worktree.state}</span>
      <span className="pool-note">{worktree.state}{worktree.claimAgeSeconds !== null && <> · <Age seconds={worktree.claimAgeSeconds} takenAt={takenAt} /></>}</span>
      <Flags flags={worktree.flags} />
    </div>
  );
}

function Events({ snapshot }: { snapshot: Snapshot }) {
  const events = snapshot.events.slice(0, EVENTS_SHOWN);
  return (
    <Module className="events" title="Activity" aside={<span className="muted">latest {events.length}</span>} footer={<SourceFreshness name="files" freshness={snapshot.sources.files} />}>
      {events.length === 0 ? <Empty>No events yet.</Empty> : (
        <ol className="event-list">
          {events.map((event, index) => (
            <li key={`${event.at}:${index}`}>
              <span className="mono muted">{clockTime(event.at)}</span>
              <span className="mono">{event.item ?? ''}</span>
              <span className="event-kind">{event.kind}</span>
              <span className="clip" title={event.message}>{event.message}</span>
            </li>
          ))}
        </ol>
      )}
    </Module>
  );
}
