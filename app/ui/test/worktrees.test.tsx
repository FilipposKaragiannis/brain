import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import type { Worktree } from '../../daemon/src/snapshot.ts';
import { Worktrees } from '../src/screens/Worktrees.tsx';
import { claudeSession, FakeDaemon, poolWorktree, snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

afterEach(cleanup);

const TWO_HOURS = 7200;

function renderWorktrees(worktrees: Worktree[]): void {
  const Wrapper = new FakeDaemon().screenWrapper();
  render(<Wrapper><Worktrees snapshot={{ ...snapshotAt(TAKEN_AT, 0), worktrees }} /></Wrapper>);
}

test('OutsideWorktree_ListedUnderItsOwnHeading', () => {
  renderWorktrees([poolWorktree('wt-2'), { ...poolWorktree('project'), role: 'main', state: 'outside' }]);
  expect(screen.getByRole('table', { name: 'Outside the pool' }).textContent, 'because the main checkout is not a pool slot and must not read like one').toMatch(/project/);
});

test('OutsideWorktree_NotInThePoolTable', () => {
  renderWorktrees([poolWorktree('wt-2'), { ...poolWorktree('elsewhere'), role: 'outside', state: 'outside' }]);
  expect(screen.getByRole('table', { name: 'Pool' }).textContent, 'because the pool table lists only what the flow can claim').not.toMatch(/elsewhere/);
});

test('SessionsColumn_ExplainsTheWordOnHover', () => {
  renderWorktrees([poolWorktree('wt-2')]);
  expect(screen.getByRole('columnheader', { name: 'Sessions' }).getAttribute('title'), 'because a session is not an agent and the header must say so').toMatch(/not an agent/i);
});

test('Session_ShowsItsCommandOnHover', () => {
  const session = claudeSession(62102, TWO_HOURS);
  renderWorktrees([{ ...poolWorktree('wt-10'), flags: ['session'], sessions: [session] }]);
  expect(screen.queryByTitle(session.command), 'because the pid alone does not say which app holds the folder').not.toBeNull();
});

test('ClaimedWorktree_LinksItsItemToTheTracker', () => {
  renderWorktrees([{ ...poolWorktree('wt-2'), state: 'claimed', item: 'gh#268', itemUrl: 'https://github.com/owner/project/issues/268', itemTitle: 'Preset retune' }]);
  expect(screen.getByRole('link', { name: 'gh#268' }).getAttribute('href'), 'because the item id opens its page').toBe('https://github.com/owner/project/issues/268');
});

test('ClaimedWorktree_ShowsTheItemTitle', () => {
  renderWorktrees([{ ...poolWorktree('wt-2'), state: 'claimed', item: 'gh#268', itemUrl: null, itemTitle: 'Preset retune' }]);
  expect(screen.queryByText('Preset retune'), 'because the id alone does not say what the worktree holds').not.toBeNull();
});

test('StaleWorktree_SaysWhy', () => {
  renderWorktrees([{ ...poolWorktree('wt-7'), state: 'stale', item: 'gh#344', staleReason: 'branch is 27 commits behind main (limit 20)' }]);
  expect(screen.queryByText(/branch is 27 commits behind main/), 'because stale is only useful with its reason').not.toBeNull();
});

test('StaleWorktree_SaysWhatToDo', () => {
  renderWorktrees([{ ...poolWorktree('wt-7'), state: 'stale', item: 'gh#344', staleReason: 'claimed 6 days ago with no run, agent or gate' }]);
  expect(screen.queryByText('Merge main in, or release the worktree.'), 'because a stale card must point at the way out').not.toBeNull();
});

test('FreeWorktreeWithASession_SaysTheSessionSitsThere', () => {
  renderWorktrees([{ ...poolWorktree('wt-10'), flags: ['session'], sessions: [claudeSession(62102, TWO_HOURS)] }]);
  expect(screen.queryByText('Free. A claude session sits here (pid 62102, 2h 00m).'), 'because free next to a live session is confusing without a word').not.toBeNull();
});
