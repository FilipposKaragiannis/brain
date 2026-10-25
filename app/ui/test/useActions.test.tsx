import { act, renderHook } from '@testing-library/react';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import type { ActionsView } from '../src/useActions.ts';
import { useActions } from '../src/useActions.ts';
import { actionRecord, FakeDaemon } from './fakeDaemon.tsx';

const ACTIONS_PATH = '/api/projects/project/actions';
const NEXT = { job: 'next' };
const HEALTH = { job: 'health' };

beforeEach(() => { vi.useFakeTimers(); });
afterEach(() => { vi.useRealTimers(); });

function daemonAccepting(): FakeDaemon {
  const daemon = new FakeDaemon();
  daemon.answer('GET', ACTIONS_PATH, () => ({ status: 200, body: { actions: [] } }));
  daemon.answer('POST', ACTIONS_PATH, () => ({ status: 202, body: { action: actionRecord('a1', 'queued', NEXT) } }));
  return daemon;
}

async function pressed(daemon: FakeDaemon): Promise<{ current: ActionsView }> {
  const { result } = renderHook(() => useActions('project'), { wrapper: daemon.wrapper() });
  act(() => { daemon.latestStream().open(); });
  await act(async () => { await result.current.run('job.run', NEXT); });
  return result;
}

test('QueuedAction_KeepsItsButtonBusy', async () => {
  const result = await pressed(daemonAccepting());
  expect(result.current.busy('job.run', NEXT), 'because a queued action must not be started twice').toBe(true);
});

test('QueuedAction_LeavesOtherButtonsFree', async () => {
  const result = await pressed(daemonAccepting());
  expect(result.current.busy('job.run', HEALTH), 'because only the button for that job waits on it').toBe(false);
});

test('RunningAction_StillBusy', async () => {
  const daemon = daemonAccepting();
  const result = await pressed(daemon);
  act(() => { daemon.latestStream().send('action', actionRecord('a1', 'running', NEXT)); });
  expect(result.current.busy('job.run', NEXT), 'because a running action is still in flight').toBe(true);
});

test('ActionDone_FreesItsButton', async () => {
  const daemon = daemonAccepting();
  const result = await pressed(daemon);
  act(() => { daemon.latestStream().send('action', actionRecord('a1', 'done', NEXT)); });
  expect(result.current.busy('job.run', NEXT), 'because the button comes back once the action ended').toBe(false);
});

test('ActionDone_ShowsTheResult', async () => {
  const daemon = daemonAccepting();
  const result = await pressed(daemon);
  act(() => { daemon.latestStream().send('action', actionRecord('a1', 'done', NEXT)); });
  const outcome = result.current.outcome('job.run', NEXT);
  expect(outcome?.kind === 'started' ? outcome.record.state : null, 'because the button reports how its last action ended').toBe('done');
});

test('LockHeld_ShowsTheRefusal', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('POST', ACTIONS_PATH, () => ({ status: 409, body: { error: 'jobs lock held by a1' } }));
  const result = await pressed(daemon);
  expect(result.current.outcome('job.run', NEXT), 'because a refused press must say why').toEqual({ kind: 'refused', status: 409, message: 'jobs lock held by a1' });
});

test('LockHeld_ButtonFreeAgain', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('POST', ACTIONS_PATH, () => ({ status: 409, body: { error: 'jobs lock held by a1' } }));
  const result = await pressed(daemon);
  expect(result.current.busy('job.run', NEXT), 'because nothing runs after a refusal, so the person may try again').toBe(false);
});

test('GateButtonNamesTheItem_BusyWhileItsAnswerRuns', async () => {
  const daemon = new FakeDaemon();
  const gateArgs = { item: 'gh#322', message: '1. keep' };
  daemon.answer('POST', ACTIONS_PATH, () => ({ status: 202, body: { action: { ...actionRecord('g1', 'running', gateArgs), kind: 'gate.clear' } } }));
  const { result } = renderHook(() => useActions('project'), { wrapper: daemon.wrapper() });
  await act(async () => { await result.current.run('gate.clear', gateArgs); });
  expect(result.current.busy('gate.clear', { item: 'gh#322' }), 'because the Answer button is identified by the item, whatever message it sent').toBe(true);
});

test('ActionsListedOnLoad_NewestFirst', async () => {
  const daemon = new FakeDaemon();
  const older = { ...actionRecord('old', 'done', NEXT), requestedAt: '2026-10-24T17:00:00Z' };
  const newer = { ...actionRecord('new', 'done', HEALTH), requestedAt: '2026-10-24T18:00:00Z' };
  daemon.answer('GET', ACTIONS_PATH, () => ({ status: 200, body: { actions: [older, newer] } }));
  const { result } = renderHook(() => useActions('project'), { wrapper: daemon.wrapper() });
  await act(async () => { await vi.advanceTimersByTimeAsync(0); });
  expect(result.current.records.map((record) => record.id), 'because the drawer lists the latest action on top').toEqual(['new', 'old']);
});
