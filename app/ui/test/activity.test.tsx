import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import type { Route } from '../src/route.ts';
import { Activity } from '../src/screens/Activity.tsx';
import { boardItem, FakeDaemon, flowEvent, HTTP_OK, snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

beforeEach(() => { vi.useFakeTimers(); });
afterEach(() => { cleanup(); vi.useRealTimers(); });

const ALL = '/api/projects/project/events?limit=200';
const FOR_515 = '/api/projects/project/events?limit=200&item=gh%23515';
const HTTP_BAD_REQUEST = 400;

async function renderActivity(daemon: FakeDaemon, item: string | null, go: (route: Route) => void): Promise<void> {
  const Wrapper = daemon.screenWrapper();
  const snapshot = { ...snapshotAt(TAKEN_AT, 0), items: [boardItem('gh#515', 'Drill catalogue')] };
  render(<Wrapper><Activity snapshot={snapshot} item={item} go={go} /></Wrapper>);
  await act(async () => { await vi.advanceTimersByTimeAsync(0); });
}

const stay = (): void => {};

test('EveryItem_ListsTheKeptEvents', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', ALL, () => ({ status: HTTP_OK, body: { events: [flowEvent(null, 'health', 'fast-forwarded wt-8')], total: 1, kept: 1 } }));
  await renderActivity(daemon, null, stay);
  expect(screen.queryByText('fast-forwarded wt-8'), 'because the screen shows every kept event').not.toBeNull();
});

test('ItemInTheRoute_ReadsOnlyThatItemsEvents', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', FOR_515, () => ({ status: HTTP_OK, body: { events: [flowEvent('gh#515', 'decomposition', 'Approve the split')], total: 1, kept: 1 } }));
  await renderActivity(daemon, 'gh#515', stay);
  expect(screen.queryByText('Approve the split'), 'because the item in the route narrows the daemon read').not.toBeNull();
});

test('EventItem_LinksToTheTracker', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', ALL, () => ({ status: HTTP_OK, body: { events: [flowEvent('gh#515', 'decomposition', 'Approve the split')], total: 1, kept: 1 } }));
  await renderActivity(daemon, null, stay);
  expect(screen.getByRole('link', { name: 'gh#515' }).getAttribute('href'), 'because an event names an item the owner may want to open').toBe('https://github.com/owner/project/issues/515');
});

test('EventKind_Shown', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', ALL, () => ({ status: HTTP_OK, body: { events: [flowEvent('gh#515', 'plan-approval', 'Re-sized')], total: 1, kept: 1 } }));
  await renderActivity(daemon, null, stay);
  expect(screen.queryByText('plan-approval'), 'because the kind says what happened at a glance').not.toBeNull();
});

test('ReadRefused_SaysWhy', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', ALL, () => ({ status: HTTP_BAD_REQUEST, body: { error: 'bad limit' } }));
  await renderActivity(daemon, null, stay);
  expect(screen.queryByText(/bad limit/), 'because an empty list must not hide a failed read').not.toBeNull();
});

test('FilterSubmitted_RoutesToThatItem', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', ALL, () => ({ status: HTTP_OK, body: { events: [], total: 0, kept: 0 } }));
  let routed: Route | null = null;
  await renderActivity(daemon, null, (route) => { routed = route; });
  fireEvent.change(screen.getByRole('searchbox'), { target: { value: ' gh#515 ' } });
  fireEvent.click(screen.getByRole('button', { name: 'Filter' }));
  expect(routed, 'because the filter is a link the owner can keep').toEqual({ projectId: 'project', screen: 'activity', detail: 'gh#515' });
});
