import { useCallback, useEffect, useRef, useState } from 'react';
import { isActive, matchesAction, upsertAction } from './actions.ts';
import type { ActionKind, ActionRecord } from './actions.ts';
import { projectPath } from './api.ts';
import { useServices } from './console.tsx';
import type { LinkState } from './stream.ts';
import { HTTP_OK, POLL_MS } from './useProject.ts';

const HTTP_ACCEPTED = 202;

/** What the last press of a button led to: the action it started, or why the daemon refused it. */
export type ActionOutcome =
  | { kind: 'started'; record: ActionRecord }
  | { kind: 'refused'; status: number; message: string };

/**
 * `busy` and `outcome` take the arguments that identify a button; any action of that kind whose
 * arguments include them counts as that button's.
 */
export type ActionsView = {
  records: ActionRecord[];
  run(kind: ActionKind, args: Record<string, string>): Promise<ActionOutcome>;
  busy(kind: ActionKind, args: Record<string, string>): boolean;
  outcome(kind: ActionKind, args: Record<string, string>): ActionOutcome | null;
  detail(actionId: string): Promise<ActionRecord | null>;
};

type Press = { id: number; kind: ActionKind; args: Record<string, string>; result: { started: string } | { refused: number; message: string } | null };

const PRESSES_KEPT = 50;
const ignore = (): void => {};

/**
 * The project's recent actions, kept live from the `action` events on the shared stream, and a
 * `run` that posts a new one. A button is busy from the press until its action is done.
 */
export function useActions(projectId: string): ActionsView {
  const { api, hub } = useServices();
  const [records, setRecords] = useState<ActionRecord[]>([]);
  const [presses, setPresses] = useState<Press[]>([]);
  const [link, setLink] = useState<LinkState>('connecting');
  const pressCount = useRef(0);

  const load = useCallback(async (): Promise<void> => {
    const response = await api.request(projectPath(projectId, '/actions'), 'GET', null);
    const listed = (response.body as { actions?: unknown } | null)?.actions;
    if (response.status !== HTTP_OK || !Array.isArray(listed)) return;
    setRecords((current) => (listed as ActionRecord[]).reduce((merged, record) => upsertAction(merged, record), current));
  }, [api, projectId]);

  useEffect(() => {
    setRecords([]);
    setPresses([]);
    void load();
    return hub.subscribe(projectId, { snapshot: ignore, action: (record) => setRecords((current) => upsertAction(current, record)), link: setLink });
  }, [hub, projectId, load]);

  useEffect(() => {
    if (link !== 'down') return;
    const timer = setInterval(() => { void load(); }, POLL_MS);
    return () => clearInterval(timer);
  }, [link, load]);

  const run = useCallback(async (kind: ActionKind, args: Record<string, string>): Promise<ActionOutcome> => {
    pressCount.current += 1;
    const id = pressCount.current;
    const settle = (result: Press['result']): void => setPresses((current) => current.map((press) => (press.id === id ? { ...press, result } : press)));
    setPresses((current) => [{ id, kind, args, result: null }, ...current].slice(0, PRESSES_KEPT));
    const response = await api.request(projectPath(projectId, '/actions'), 'POST', { kind, args });
    const record = (response.body as { action?: ActionRecord } | null)?.action;
    if (response.status === HTTP_ACCEPTED && record !== undefined) {
      setRecords((current) => upsertAction(current, record));
      settle({ started: record.id });
      return { kind: 'started', record };
    }
    const message = refusalMessage(response.status, response.body);
    settle({ refused: response.status, message });
    return { kind: 'refused', status: response.status, message };
  }, [api, projectId]);

  const busy = useCallback((kind: ActionKind, args: Record<string, string>): boolean => {
    const posting = presses.some((press) => press.result === null && matchesAction(kind, args, press.kind, press.args));
    return posting || records.some((record) => isActive(record.state) && matchesAction(kind, args, record.kind, record.args));
  }, [presses, records]);

  const outcome = useCallback((kind: ActionKind, args: Record<string, string>): ActionOutcome | null => {
    const last = presses.find((press) => press.result !== null && matchesAction(kind, args, press.kind, press.args))?.result ?? null;
    if (last === null) return null;
    if ('refused' in last) return { kind: 'refused', status: last.refused, message: last.message };
    const record = records.find((candidate) => candidate.id === last.started);
    return record === undefined ? null : { kind: 'started', record };
  }, [presses, records]);

  const detail = useCallback(async (actionId: string): Promise<ActionRecord | null> => {
    const response = await api.request(projectPath(projectId, `/actions/${encodeURIComponent(actionId)}`), 'GET', null);
    if (response.status !== HTTP_OK || response.body === null) return null;
    const record = response.body as ActionRecord;
    setRecords((current) => upsertAction(current, record));
    return record;
  }, [api, projectId]);

  return { records, run, busy, outcome, detail };
}

function refusalMessage(status: number, body: unknown): string {
  const error = (body as { error?: unknown } | null)?.error;
  if (typeof error === 'string' && error !== '') return error;
  return status === 0 ? 'the daemon did not answer' : `the daemon answered ${status}`;
}
