import { useState } from 'react';
import type { Snapshot } from '../../../daemon/src/snapshot.ts';
import { DAEMON_RETRY_MS } from '../api.ts';
import { clockTime, Since } from '../clock.tsx';
import { ItemLink } from '../links.tsx';
import type { Route } from '../route.ts';
import { Empty, Module, SourceFreshness } from '../ui.tsx';
import { useEventLog } from '../useEventLog.ts';

const MILLISECONDS_PER_SECOND = 1000;

/** Every event the daemon keeps, newest first, narrowed to one item when the route names one. */
export function Activity({ snapshot, item, go }: { snapshot: Snapshot; item: string | null; go: (route: Route) => void }) {
  const projectId = snapshot.project.id;
  const revision = snapshot.takenAt;
  const log = useEventLog(projectId, item, revision);
  const [filter, setFilter] = useState(item ?? '');
  const show = (next: string): void => go({ projectId, screen: 'activity', detail: next === '' ? null : next });
  const page = log.page;
  const aside = page === null ? null : <span className="muted">{page.events.length} of {page.total}{item === null ? '' : ` for ${item}`}</span>;
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
        {log.error !== null && <p className="banner tone-failing" role="alert">{log.error}. Trying again every {DAEMON_RETRY_MS / MILLISECONDS_PER_SECOND} s.</p>}
        {page === null && log.error === null && <Empty>Reading the events…</Empty>}
        {page !== null && page.events.length === 0 && <Empty>{item === null ? 'No events yet.' : `No event names ${item}.`}</Empty>}
        {page !== null && page.events.length > 0 && (
          <div className="scroll">
            <table className="table activity-table">
              <thead><tr><th>When</th><th>Item</th><th>Kind</th><th>Message</th></tr></thead>
              <tbody>
                {page.events.map((event, index) => (
                  <tr key={`${event.at}:${index}`}>
                    <td className="mono nowrap" title={`${event.at} (${clockTime(event.at)})`}><Since at={event.at} /></td>
                    <td className="nowrap">{event.item === null ? '—' : <ItemLink id={event.item} pages={snapshot} />}</td>
                    <td className="event-kind nowrap">{event.kind}</td>
                    <td className="event-message-cell"><EventMessage message={event.message} /></td>
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

/** Past this many characters a message folds to three lines with a button that unfolds it. */
const FOLDED_CHARACTERS = 240;

function EventMessage({ message }: { message: string }) {
  const [open, setOpen] = useState(false);
  if (message.length <= FOLDED_CHARACTERS) return <span className="event-message open">{message}</span>;
  return (
    <>
      <span className={open ? 'event-message open' : 'event-message'}>{message}</span>
      <button type="button" className="row-link more" aria-expanded={open} onClick={() => setOpen((shown) => !shown)}>{open ? 'Less' : 'More'}</button>
    </>
  );
}
