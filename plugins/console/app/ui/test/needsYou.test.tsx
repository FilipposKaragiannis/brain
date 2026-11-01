import { cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import type { AttentionRow } from '../../daemon/src/snapshot.ts';
import type { Route } from '../src/route.ts';
import { NeedsYou } from '../src/screens/NeedsYou.tsx';
import { FakeDaemon, snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

afterEach(cleanup);

function renderRow(row: AttentionRow): Route[] {
  const routes: Route[] = [];
  const Wrapper = new FakeDaemon().screenWrapper();
  render(<Wrapper><NeedsYou snapshot={{ ...snapshotAt(TAKEN_AT, 1), attention: [row] }} go={(route) => routes.push(route)} /></Wrapper>);
  return routes;
}

test('HostStoppedRow_Open_GoesToJobs', () => {
  const routes = renderRow({ kind: 'host-stopped', id: 'codex', title: 'codex is stopped', detail: 'usage limit', worktree: null, sinceAt: TAKEN_AT, ageSeconds: 60, action: null });
  fireEvent.click(screen.getByRole('button', { name: 'Open' }));
  expect(routes, 'because a stopped host stops the jobs, and its card sits on the Jobs page').toEqual([{ projectId: 'project', screen: 'jobs', detail: null }]);
});

test('JobFailedRow_Open_GoesToJobs', () => {
  const routes = renderRow({ kind: 'job-failed', id: 'health', title: 'health job failed', detail: 'exit 1', worktree: null, sinceAt: TAKEN_AT, ageSeconds: 60, action: null });
  fireEvent.click(screen.getByRole('button', { name: 'Open' }));
  expect(routes, 'because the failed run shows in that job\'s history on the Jobs page').toEqual([{ projectId: 'project', screen: 'jobs', detail: null }]);
});
