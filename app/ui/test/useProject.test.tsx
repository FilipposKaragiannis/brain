import { act, renderHook } from '@testing-library/react';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import { POLL_MS, useProject } from '../src/useProject.ts';
import { FakeDaemon, snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

const SNAPSHOT_PATH = '/api/projects/project/snapshot';
const STREAMED_NEEDS_YOU = 2;
const POLLED_NEEDS_YOU = 3;
const LATER_NEEDS_YOU = 4;
const LATER = '2026-10-24T18:17:04Z';

beforeEach(() => { vi.useFakeTimers(); });
afterEach(() => { vi.useRealTimers(); });

async function flush(): Promise<void> {
  await act(async () => { await vi.advanceTimersByTimeAsync(0); });
}

test('StreamedSnapshot_IsTheLatest', () => {
  const daemon = new FakeDaemon();
  const { result } = renderHook(() => useProject('project'), { wrapper: daemon.wrapper() });
  act(() => { daemon.latestStream().open(); daemon.latestStream().send('snapshot', snapshotAt(TAKEN_AT, STREAMED_NEEDS_YOU)); });
  expect(result.current.snapshot?.counts.needsYou, 'because the stream carries the current picture').toBe(STREAMED_NEEDS_YOU);
});

test('OpenStream_ReportsConnected', () => {
  const daemon = new FakeDaemon();
  const { result } = renderHook(() => useProject('project'), { wrapper: daemon.wrapper() });
  act(() => { daemon.latestStream().open(); });
  expect(result.current.connected, 'because events can flow once the stream is open').toBe(true);
});

test('DroppedStream_ReportsDisconnected', () => {
  const daemon = new FakeDaemon();
  const { result } = renderHook(() => useProject('project'), { wrapper: daemon.wrapper() });
  act(() => { daemon.latestStream().open(); daemon.latestStream().drop(); });
  expect(result.current.connected, 'because the page must say when it stopped hearing the daemon').toBe(false);
});

test('DroppedStream_ReadsTheSnapshotAtOnce', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', SNAPSHOT_PATH, () => ({ status: 200, body: snapshotAt(LATER, POLLED_NEEDS_YOU) }));
  const { result } = renderHook(() => useProject('project'), { wrapper: daemon.wrapper() });
  act(() => { daemon.latestStream().open(); daemon.latestStream().send('snapshot', snapshotAt(TAKEN_AT, STREAMED_NEEDS_YOU)); daemon.latestStream().drop(); });
  await flush();
  expect(result.current.snapshot?.counts.needsYou, 'because the fallback fetches the snapshot as soon as the stream drops').toBe(POLLED_NEEDS_YOU);
});

test('StreamStaysDown_PollsEveryThirtySeconds', async () => {
  const daemon = new FakeDaemon();
  let served = snapshotAt(TAKEN_AT, POLLED_NEEDS_YOU);
  daemon.answer('GET', SNAPSHOT_PATH, () => ({ status: 200, body: served }));
  const { result } = renderHook(() => useProject('project'), { wrapper: daemon.wrapper() });
  act(() => { daemon.latestStream().drop(); });
  await flush();
  served = snapshotAt(LATER, LATER_NEEDS_YOU);
  await act(async () => { await vi.advanceTimersByTimeAsync(POLL_MS - 1); });
  expect(result.current.snapshot?.counts.needsYou, 'because the next poll is not due before thirty seconds').toBe(POLLED_NEEDS_YOU);
  await act(async () => { await vi.advanceTimersByTimeAsync(1); });
  expect(result.current.snapshot?.counts.needsYou, 'because the poll at thirty seconds picks up the newer snapshot').toBe(LATER_NEEDS_YOU);
});

test('StreamBackAfterPolling_ConnectedAgain', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', SNAPSHOT_PATH, () => ({ status: 200, body: snapshotAt(TAKEN_AT, POLLED_NEEDS_YOU) }));
  const { result } = renderHook(() => useProject('project'), { wrapper: daemon.wrapper() });
  act(() => { daemon.latestStream().drop(); });
  await act(async () => { await vi.advanceTimersByTimeAsync(POLL_MS); });
  act(() => { daemon.latestStream().open(); });
  expect(result.current.connected, 'because each poll tick tries the stream again and the reopened one is live').toBe(true);
});
