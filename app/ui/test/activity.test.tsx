import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import type { ReactNode } from 'react';
import { DAEMON_RETRY_MS } from '../src/api.ts';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import type { Route } from '../src/route.ts';
import { routeHash } from '../src/route.ts';
import { Activity } from '../src/screens/Activity.tsx';
import { boardItem, FakeDaemon, flowEvent, HTTP_OK, snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

beforeEach(() => { vi.useFakeTimers(); window.location.hash = ''; });
afterEach(() => { cleanup(); vi.useRealTimers(); });

const ALL = '/api/projects/project/events?limit=200';
const FOR_515 = '/api/projects/project/events?limit=200&item=gh%23515';
const HTTP_BAD_REQUEST = 400;

const LATER = '2026-10-24T18:17:04Z';
const HTTP_UNAUTHORIZED = 401;
const NETWORK_DOWN = 0;

function screenAt(takenAt: string, item: string | null): ReactNode {
  const snapshot = { ...snapshotAt(takenAt, 0), items: [boardItem('gh#515', 'Drill catalogue')] };
  return <Activity snapshot={snapshot} item={item} go={go} />;
}

function go(route: Route): void {
  window.location.hash = routeHash(route);
}

async function flush(milliseconds: number): Promise<void> {
  await act(async () => { await vi.advanceTimersByTimeAsync(milliseconds); });
}

async function renderActivity(daemon: FakeDaemon, item: string | null): Promise<(takenAt: string) => Promise<void>> {
  const Wrapper = daemon.screenWrapper();
  const { rerender } = render(<Wrapper>{screenAt(TAKEN_AT, item)}</Wrapper>);
  await flush(0);
  return async (takenAt) => { rerender(<Wrapper>{screenAt(takenAt, item)}</Wrapper>); await flush(0); };
}

function answering(events: ReturnType<typeof flowEvent>[]): () => { status: number; body: unknown } {
  return () => ({ status: HTTP_OK, body: { events, total: events.length, kept: events.length } });
}

test('EveryItem_ListsTheKeptEvents', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', ALL, () => ({ status: HTTP_OK, body: { events: [flowEvent(null, 'health', 'fast-forwarded wt-8')], total: 1, kept: 1 } }));
  await renderActivity(daemon, null);
  expect(screen.queryByText('fast-forwarded wt-8'), 'because the screen shows every kept event').not.toBeNull();
});

test('ItemInTheRoute_ReadsOnlyThatItemsEvents', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', FOR_515, () => ({ status: HTTP_OK, body: { events: [flowEvent('gh#515', 'decomposition', 'Approve the split')], total: 1, kept: 1 } }));
  await renderActivity(daemon, 'gh#515');
  expect(screen.queryByText('Approve the split'), 'because the item in the route narrows the daemon read').not.toBeNull();
});

test('EventItem_LinksToTheTracker', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', ALL, () => ({ status: HTTP_OK, body: { events: [flowEvent('gh#515', 'decomposition', 'Approve the split')], total: 1, kept: 1 } }));
  await renderActivity(daemon, null);
  expect(screen.getByRole('link', { name: 'gh#515' }).getAttribute('href'), 'because an event names an item the owner may want to open').toBe('https://github.com/owner/project/issues/515');
});

test('EventKind_Shown', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', ALL, () => ({ status: HTTP_OK, body: { events: [flowEvent('gh#515', 'plan-approval', 'Re-sized')], total: 1, kept: 1 } }));
  await renderActivity(daemon, null);
  expect(screen.queryByText('plan-approval'), 'because the kind says what happened at a glance').not.toBeNull();
});

test('ReadRefused_SaysWhy', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', ALL, () => ({ status: HTTP_BAD_REQUEST, body: { error: 'bad limit' } }));
  await renderActivity(daemon, null);
  expect(screen.queryByText(/bad limit/), 'because an empty list must not hide a failed read').not.toBeNull();
});

test('FilterSubmitted_RoutesToThatItem', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', ALL, answering([]));
  await renderActivity(daemon, null);
  fireEvent.change(screen.getByRole('searchbox'), { target: { value: ' gh#515 ' } });
  fireEvent.click(screen.getByRole('button', { name: 'Filter' }));
  expect(window.location.hash, 'because the filter is a link the owner can keep').toBe('#/project/activity/gh%23515');
});

test('TokenRefused_SaysATokenIsNeeded', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', ALL, () => ({ status: HTTP_UNAUTHORIZED, body: { error: 'token required' } }));
  await renderActivity(daemon, null);
  expect(screen.queryByText(/token needed/i), 'because a 401 says the same thing on every screen').not.toBeNull();
});

test('DaemonDown_SaysNotReachable', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', ALL, () => ({ status: NETWORK_DOWN, body: { error: 'fetch failed' } }));
  await renderActivity(daemon, null);
  expect(screen.queryByText(/daemon not reachable/i), 'because a daemon that is down must not read as a list with no events').not.toBeNull();
});

test('DaemonBackAfterAFailedRead_ShowsTheEvents', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', ALL, () => ({ status: NETWORK_DOWN, body: null }));
  await renderActivity(daemon, null);
  daemon.answer('GET', ALL, answering([flowEvent('gh#515', 'merge', 'Opened PR #560')]));
  await flush(DAEMON_RETRY_MS);
  expect(screen.queryByText('Opened PR #560'), 'because the screen asks again while it has no answer').not.toBeNull();
});

test('ReadFailsAfterALoad_KeepsTheEventsItHad', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', ALL, answering([flowEvent('gh#515', 'merge', 'Opened PR #560')]));
  const showSnapshot = await renderActivity(daemon, null);
  daemon.answer('GET', ALL, () => ({ status: NETWORK_DOWN, body: null }));
  await showSnapshot(LATER);
  expect(screen.queryByText('Opened PR #560'), 'because a failed read is a banner, not an empty page').not.toBeNull();
});

test('NewSnapshot_ReadsTheEventsAgain', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', ALL, answering([flowEvent('gh#515', 'merge', 'Opened PR #560')]));
  const showSnapshot = await renderActivity(daemon, null);
  daemon.answer('GET', ALL, answering([flowEvent('gh#515', 'gate', 'Merge gate raised'), flowEvent('gh#515', 'merge', 'Opened PR #560')]));
  await showSnapshot(LATER);
  expect(screen.queryByText('Merge gate raised'), 'because an event written in the same second as the newest must still show').not.toBeNull();
});

test('LongMessage_UnfoldsOnMore', async () => {
  const daemon = new FakeDaemon();
  const long = `Approve the split. ${'Sub-item body. '.repeat(30)}`;
  daemon.answer('GET', ALL, answering([flowEvent('gh#515', 'decomposition', long)]));
  await renderActivity(daemon, null);
  fireEvent.click(screen.getByRole('button', { name: 'More' }));
  expect(screen.getByRole('button', { name: 'Less' }).getAttribute('aria-expanded'), 'because the full message must be readable without a hover').toBe('true');
});
