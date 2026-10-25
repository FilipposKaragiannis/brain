import { act, renderHook } from '@testing-library/react';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import type { ActionsView } from '../src/useActions.ts';
import { useActions } from '../src/useActions.ts';
import { actionRecord, FakeDaemon, HTTP_ACCEPTED, HTTP_CONFLICT, HTTP_OK } from './fakeDaemon.tsx';

const ACTIONS_PATH = '/api/projects/project/actions';
const NEXT = { job: 'next' };
const HEALTH = { job: 'health' };
const LOCK_HELD = 'job:next is held by a1';
const EVENTS_BEFORE_REPLY = 2;

beforeEach(() => { vi.useFakeTimers(); });
afterEach(() => { vi.useRealTimers(); });

function daemonAccepting(): FakeDaemon {
  const daemon = new FakeDaemon();
  daemon.answer('GET', ACTIONS_PATH, () => ({ status: HTTP_OK, body: { actions: [] } }));
  daemon.answer('POST', ACTIONS_PATH, () => ({ status: HTTP_ACCEPTED, body: { action: actionRecord('a1', 'running', NEXT) } }));
  return daemon;
}

function refusing(): FakeDaemon {
  const daemon = new FakeDaemon();
  daemon.answer('POST', ACTIONS_PATH, () => ({ status: HTTP_CONFLICT, body: { error: LOCK_HELD } }));
  return daemon;
}

async function pressed(daemon: FakeDaemon): Promise<{ current: ActionsView }> {
  const { result } = renderHook(() => useActions('project'), { wrapper: daemon.wrapper() });
  act(() => { daemon.latestStream().open(); });
  await act(async () => { await result.current.run('job.run', NEXT); });
  return result;
}

async function flush(): Promise<void> {
  await act(async () => { await vi.advanceTimersByTimeAsync(0); });
}

test('RunningAction_KeepsItsButtonBusy', async () => {
  const result = await pressed(daemonAccepting());
  expect(result.current.busy('job.run', NEXT), 'because a running action must not be started twice').toBe(true);
});

test('RunningAction_LeavesOtherButtonsFree', async () => {
  const result = await pressed(daemonAccepting());
  expect(result.current.busy('job.run', HEALTH), 'because only the button for that job waits on it').toBe(false);
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

test('LateReplyAfterStreamSaidDone_StaysDone', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', ACTIONS_PATH, () => ({ status: HTTP_OK, body: { actions: [] } }));
  daemon.answerAfterEvents('POST', ACTIONS_PATH, EVENTS_BEFORE_REPLY, () => ({ status: HTTP_ACCEPTED, body: { action: actionRecord('a1', 'running', NEXT) } }));
  const { result } = renderHook(() => useActions('project'), { wrapper: daemon.wrapper() });
  act(() => { daemon.latestStream().open(); });
  let reply: Promise<unknown> = Promise.resolve();
  act(() => { reply = result.current.run('job.run', NEXT); });
  await act(async () => {
    daemon.latestStream().send('action', actionRecord('a1', 'running', NEXT));
    daemon.latestStream().send('action', actionRecord('a1', 'done', NEXT));
    await reply;
  });
  expect(result.current.records[0]?.state, 'because a POST reply that arrives after the stream said done must not bring the action back to running').toBe('done');
});

test('LateReplyAfterStreamSaidDone_ButtonFree', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', ACTIONS_PATH, () => ({ status: HTTP_OK, body: { actions: [] } }));
  daemon.answerAfterEvents('POST', ACTIONS_PATH, EVENTS_BEFORE_REPLY, () => ({ status: HTTP_ACCEPTED, body: { action: actionRecord('a1', 'running', NEXT) } }));
  const { result } = renderHook(() => useActions('project'), { wrapper: daemon.wrapper() });
  act(() => { daemon.latestStream().open(); });
  let reply: Promise<unknown> = Promise.resolve();
  act(() => { reply = result.current.run('job.run', NEXT); });
  await act(async () => {
    daemon.latestStream().send('action', actionRecord('a1', 'running', NEXT));
    daemon.latestStream().send('action', actionRecord('a1', 'done', NEXT));
    await reply;
  });
  expect(result.current.busy('job.run', NEXT), 'because the action ended, whatever order the replies came in').toBe(false);
});

test('ActionEndedWhileStreamBlinked_ButtonFreeAfterReopen', async () => {
  const daemon = daemonAccepting();
  const result = await pressed(daemon);
  daemon.answer('GET', ACTIONS_PATH, () => ({ status: HTTP_OK, body: { actions: [actionRecord('a1', 'done', NEXT)] } }));
  act(() => { daemon.latestStream().interrupt(); });
  act(() => { daemon.latestStream().reopen(); });
  await flush();
  expect(result.current.busy('job.run', NEXT), 'because the list read after the stream reopens shows the done the stream missed').toBe(false);
});

test('DaemonRestartedWhileStreamBlinked_ButtonFreeAfterReopen', async () => {
  const daemon = daemonAccepting();
  const result = await pressed(daemon);
  act(() => { daemon.latestStream().interrupt(); });
  act(() => { daemon.latestStream().reopen(); });
  await flush();
  expect(result.current.busy('job.run', NEXT), 'because an action the daemon no longer lists died with its memory and is no longer running').toBe(false);
});

test('LockHeld_ShowsTheRefusal', async () => {
  const result = await pressed(refusing());
  expect(result.current.outcome('job.run', NEXT), 'because a refused press must say why').toEqual({ kind: 'refused', status: HTTP_CONFLICT, message: LOCK_HELD });
});

test('LockHeld_ButtonFreeAgain', async () => {
  const result = await pressed(refusing());
  expect(result.current.busy('job.run', NEXT), 'because nothing runs after a refusal, so the person may try again').toBe(false);
});

test('GateButtonNamesTheItem_BusyWhileItsAnswerRuns', async () => {
  const daemon = new FakeDaemon();
  const gateArgs = { item: 'gh#322', message: '1. keep' };
  daemon.answer('POST', ACTIONS_PATH, () => ({ status: HTTP_ACCEPTED, body: { action: { ...actionRecord('g1', 'running', gateArgs), kind: 'gate.clear' } } }));
  const { result } = renderHook(() => useActions('project'), { wrapper: daemon.wrapper() });
  await act(async () => { await result.current.run('gate.clear', gateArgs); });
  expect(result.current.busy('gate.clear', { item: 'gh#322' }), 'because the Answer button is identified by the item, whatever message it sent').toBe(true);
});

test('ActionsListedOnLoad_NewestFirst', async () => {
  const daemon = new FakeDaemon();
  const older = { ...actionRecord('old', 'done', NEXT), requestedAt: '2026-10-24T17:00:00Z' };
  const newer = { ...actionRecord('new', 'done', HEALTH), requestedAt: '2026-10-24T18:00:00Z' };
  daemon.answer('GET', ACTIONS_PATH, () => ({ status: HTTP_OK, body: { actions: [older, newer] } }));
  const { result } = renderHook(() => useActions('project'), { wrapper: daemon.wrapper() });
  await flush();
  expect(result.current.records.map((record) => record.id), 'because the drawer lists the latest action on top').toEqual(['new', 'old']);
});
