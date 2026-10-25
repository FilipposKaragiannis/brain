import { useState } from 'react';
import type { Snapshot } from '../../../daemon/src/snapshot.ts';
import { clockTime, Since } from '../clock.tsx';
import { ItemLink } from '../links.tsx';
import type { Route } from '../route.ts';
import { Empty, Module, SourceFreshness } from '../ui.tsx';
import { useEventLog } from '../useEventLog.ts';

/** Every event the daemon keeps, newest first, narrowed to one item when the route names one. */
export function Activity({ snapshot, item, go }: { snapshot: Snapshot; item: string | null; go: (route: Route) => void }) {
  const projectId = snapshot.project.id;
  const revision = `${snapshot.events[0]?.at ?? ''}:${snapshot.events.length}`;
  const log = useEventLog(projectId, item, revision);
  const [filter, setFilter] = useState(item ?? '');
  const show = (next: string): void => go({ projectId, screen: 'activity', detail: next === '' ? null : next });
  const aside = log.kind === 'loaded' ? <span className="muted">{log.events.length} of {log.total}{item === null ? '' : ` for ${item}`}</span> : null;
  return (
    <div className="screen">
      <Module className="activity" title="Activity" aside={aside} footer={<SourceFreshness name="files" freshness={snapshot.sources.files} />}>
        <form className="filter" role="search" onSubmit={(event) => { event.preventDefault(); show(filter.trim()); }}>
          <label className="field filter-field">
            <span>Item</span>
            <input type="search" placeholder="gh#12" value={filter} onChange={(event) => setFilter(event.target.value)} />
          </label>
          <button type="submit" className="button">Filter</button>
          {item !== null && <button type="button" className="button" onClick={() => { setFilter(''); show(''); }}>Show every item</button>}
        </form>
        {log.kind === 'loading' && <Empty>Reading the events…</Empty>}
        {log.kind === 'failed' && <Empty>{log.message}.</Empty>}
        {log.kind === 'loaded' && log.events.length === 0 && <Empty>{item === null ? 'No events yet.' : `No event names ${item}.`}</Empty>}
        {log.kind === 'loaded' && log.events.length > 0 && (
          <div className="scroll">
            <table className="table activity-table">
              <thead><tr><th>When</th><th>Item</th><th>Kind</th><th>Message</th></tr></thead>
              <tbody>
                {log.events.map((event, index) => (
                  <tr key={`${event.at}:${index}`}>
                    <td className="mono nowrap" title={`${event.at} (${clockTime(event.at)})`}><Since at={event.at} /></td>
                    <td className="nowrap">{event.item === null ? '—' : <ItemLink id={event.item} pages={snapshot} />}</td>
                    <td className="event-kind nowrap">{event.kind}</td>
                    <td className="event-message-cell"><span className="event-message" title={event.message}>{event.message}</span></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </Module>
    </div>
  );
}
