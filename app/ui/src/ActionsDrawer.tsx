import { useEffect, useRef, useState } from 'react';
import type { ActionRecord } from './actions.ts';
import { isActive } from './actions.ts';
import { clockTime } from './clock.tsx';
import { actionTone } from './status.ts';
import { Chip, Empty } from './ui.tsx';
import type { ActionsView } from './useActions.ts';

/** Recent actions with their state, and the live output of the one selected. */
export function ActionsDrawer({ actions, close }: { actions: ActionsView; close: () => void }) {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const selected = actions.records.find((record) => record.id === selectedId) ?? actions.records[0] ?? null;
  const closeButton = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    closeButton.current?.focus();
    const onKey = (event: KeyboardEvent): void => { if (event.key === 'Escape') close(); };
    document.addEventListener('keydown', onKey);
    return () => { document.removeEventListener('keydown', onKey); opener?.focus(); };
  }, [close]);
  return (
    <aside className="drawer" role="dialog" aria-modal="true" aria-labelledby="actions-title">
      <header className="module-head"><h2 id="actions-title">Actions</h2><button ref={closeButton} type="button" className="button" onClick={close}>Close</button></header>
      {actions.records.length === 0 ? <Empty>No action has run yet.</Empty> : (
        <div className="drawer-body">
          <ul className="list action-list">
            {actions.records.map((record) => (
              <li key={record.id}>
                <button type="button" className={record.id === selected?.id ? 'list-row selected' : 'list-row'} onClick={() => setSelectedId(record.id)}>
                  <Chip tone={actionTone(record.state)}>{record.state}</Chip>
                  <span className="mono">{record.kind}</span>
                  <span className="muted clip">{describeArgs(record.args)}</span>
                  <span className="mono muted">{clockTime(record.requestedAt)}</span>
                </button>
              </li>
            ))}
          </ul>
          {selected !== null && <ActionOutput record={selected} actions={actions} />}
        </div>
      )}
    </aside>
  );
}

function ActionOutput({ record, actions }: { record: ActionRecord; actions: ActionsView }) {
  const needsFull = !isActive(record.state) && record.output === undefined && record.outputBytes > byteLength(record.outputTail);
  const { detail } = actions;
  useEffect(() => { if (needsFull) void detail(record.id); }, [needsFull, detail, record.id]);
  const text = record.output ?? record.outputTail;
  return (
    <div className="action-output">
      <div className="action-meta">
        <span className="mono">{record.command.join(' ')}</span>
        <span className="muted">
          {record.exitCode !== null && `exit ${record.exitCode} · `}{record.timedOut && 'timed out · '}{record.locks.length > 0 && `holds ${record.locks.join(', ')} · `}{record.outputBytes} bytes
        </span>
      </div>
      <pre className="terminal">{text === '' ? (isActive(record.state) ? 'waiting for output…' : 'no output') : text}</pre>
    </div>
  );
}

function byteLength(text: string): number {
  return new TextEncoder().encode(text).length;
}

function describeArgs(args: Record<string, string>): string {
  return Object.entries(args).filter(([name]) => name !== 'message').map(([name, value]) => `${name}=${value}`).join(' ');
}
