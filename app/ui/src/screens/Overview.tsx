import type { Snapshot, SourceName, Worktree } from '../../../daemon/src/snapshot.ts';
import { Age, clockTime } from '../clock.tsx';
import { ItemLink } from '../links.tsx';
import type { ItemPages } from '../links.tsx';
import { readinessSentence } from '../readiness.ts';
import type { Route } from '../route.ts';
import { routeHash } from '../route.ts';
import { countTone, worktreeTone } from '../status.ts';
import type { Tone } from '../status.ts';
import { Dot, Empty, Flags, Module, SourceFreshness } from '../ui.tsx';
import { Disagreements } from './Disagreements.tsx';
import { NeedsYou } from './NeedsYou.tsx';

const EVENTS_SHOWN = 30;
const SOURCE_NAMES: SourceName[] = ['files', 'git', 'processes', 'jobs', 'board', 'pulls'];

/** A tile links to the screen that explains its count; `null` when no other screen does. */
type Tile = { label: string; count: number; tone: Tone; screen: Route['screen'] | null };

export function Overview({ snapshot, go }: { snapshot: Snapshot; go: (route: Route) => void }) {
  const projectId = snapshot.project.id;
  const counts = snapshot.counts;
  const tiles: Tile[] = [
    { label: 'Needs you', count: counts.needsYou, tone: countTone(counts.needsYou, 'needs-you'), screen: 'gates' },
    { label: 'Running', count: counts.running, tone: countTone(counts.running, 'running'), screen: 'agents' },
    { label: 'Stale', count: counts.stale, tone: countTone(counts.stale, 'stale'), screen: 'worktrees' },
    { label: 'Free', count: counts.free, tone: 'quiet', screen: 'worktrees' },
    { label: 'Disagreements', count: counts.disagreements, tone: countTone(counts.disagreements, 'failing'), screen: null },
  ];
  return (
    <div className="screen">
      <section className="tiles" aria-label="Status">
        {tiles.map((tile) => {
          const body = <><span className="tile-label">{tile.label}<Dot tone={tile.tone} /></span><span className="tile-count">{tile.count}</span></>;
          return tile.screen === null
            ? <div key={tile.label} className={`tile tone-${tile.tone}`}>{body}</div>
            : <a key={tile.label} className={`tile tone-${tile.tone}`} href={routeHash({ projectId, screen: tile.screen, detail: null })}>{body}</a>;
        })}
      </section>
      <p className="readiness" aria-label="Readiness">{readinessSentence(snapshot.readiness, counts, snapshot.worktrees)}</p>
      <div className="columns">
        <NeedsYou snapshot={snapshot} go={go} />
        <Events snapshot={snapshot} />
      </div>
      <Disagreements snapshot={snapshot} />
      <Pool snapshot={snapshot} />
      <Module className="sources" title="Sources" aside={null} footer={<span>taken at {clockTime(snapshot.takenAt)} · <Age seconds={0} takenAt={snapshot.takenAt} /> ago</span>}>
        <ul className="source-strip">
          {SOURCE_NAMES.map((name) => <li key={name}><SourceFreshness name={name} freshness={snapshot.sources[name]} /></li>)}
        </ul>
      </Module>
    </div>
  );
}

function Pool({ snapshot }: { snapshot: Snapshot }) {
  const pool = snapshot.worktrees.filter((worktree) => worktree.role === 'pool');
  const max = snapshot.project.poolMax;
  return (
    <Module className="pool" title="Pool" aside={<span className="muted">{pool.length}{max === null ? '' : ` of ${max}`} · base {snapshot.project.base}</span>} footer={<SourceFreshness name="git" freshness={snapshot.sources.git} />}>
      {pool.length === 0 ? <Empty>No pool worktrees.</Empty> : (
        <div className="pool-map">{pool.map((worktree) => <PoolCell key={worktree.name} worktree={worktree} pages={snapshot} takenAt={snapshot.takenAt} />)}</div>
      )}
    </Module>
  );
}

function PoolCell({ worktree, pages, takenAt }: { worktree: Worktree; pages: ItemPages; takenAt: string }) {
  const tone = worktreeTone(worktree.state);
  return (
    <div className={`pool-cell tone-${tone}`}>
      <span className="pool-name" title={`${worktree.name}: ${worktree.state}`}><span className="mono">{worktree.name}</span><Dot tone={tone} /></span>
      {worktree.item === null
        ? <span className="pool-item">{worktree.state}</span>
        : <span className="pool-item"><ItemLink id={worktree.item} pages={pages} />{worktree.itemTitle !== null && <span className="pool-title">{worktree.itemTitle}</span>}</span>}
      <span className="pool-note">{worktree.state}{worktree.claimAgeSeconds !== null && <> · <Age seconds={worktree.claimAgeSeconds} takenAt={takenAt} /></>}</span>
      <Flags flags={worktree.flags} />
    </div>
  );
}

function Events({ snapshot }: { snapshot: Snapshot }) {
  const events = snapshot.events.slice(0, EVENTS_SHOWN);
  const all = routeHash({ projectId: snapshot.project.id, screen: 'activity', detail: null });
  return (
    <Module className="events" title="Activity" aside={<span className="muted">latest {events.length} · <a href={all}>Show all</a></span>} footer={<SourceFreshness name="files" freshness={snapshot.sources.files} />}>
      {events.length === 0 ? <Empty>No events yet.</Empty> : (
        <ol className="event-list">
          {events.map((event, index) => (
            <li key={`${event.at}:${index}`}>
              <span className="mono muted">{clockTime(event.at)}</span>
              <span>{event.item === null ? '' : <ItemLink id={event.item} pages={snapshot} />}</span>
              <span className="event-kind">{event.kind}</span>
              <span className="clip" title={event.message}>{event.message}</span>
            </li>
          ))}
        </ol>
      )}
    </Module>
  );
}
