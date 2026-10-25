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

const CLAIM = { item: 'gh#344', branch: 'flow/gh-344', base: 'epic/gh-300', step: 'implement', claimedAt: TAKEN_AT, host: 'claude' };

test('BranchFarBehind_SaysMergeTheClaimsBaseIn', () => {
  renderWorktrees([{ ...poolWorktree('wt-7'), state: 'stale', flags: ['stale-branch'], claim: CLAIM, item: 'gh#344', staleReason: 'branch is 27 commits behind epic/gh-300 (limit 20)' }]);
  expect(screen.getByText(/or release the worktree/).textContent, 'because the branch catches up with the base it was claimed from, not the project default').toMatch(/Merge epic\/gh-300 in/);
});

test('IdleClaim_SaysRunTheNextStep', () => {
  renderWorktrees([{ ...poolWorktree('wt-5'), state: 'stale', flags: ['idle'], claim: CLAIM, item: 'gh#341', staleReason: 'claimed 5 days ago with no run, agent or gate' }]);
  expect(screen.getByText(/or release the worktree/).textContent, 'because an idle claim is not behind, so merging fixes nothing').toMatch(/next step/);
});

test('IdleClaim_DoesNotAskForAMerge', () => {
  renderWorktrees([{ ...poolWorktree('wt-5'), state: 'stale', flags: ['idle'], claim: CLAIM, item: 'gh#341', staleReason: 'claimed 5 days ago with no run, agent or gate' }]);
  expect(screen.getByText(/or release the worktree/).textContent, 'because a merge is the wrong way out for an idle claim').not.toMatch(/Merge/);
});

test('BehindAndIdle_SaysBoth', () => {
  renderWorktrees([{ ...poolWorktree('wt-7'), state: 'stale', flags: ['stale-branch', 'idle'], claim: CLAIM, item: 'gh#344', staleReason: 'branch is 27 commits behind; claimed 5 days ago' }]);
  expect(screen.getByText(/or release the worktree/).textContent, 'because each reason has its own way out').toMatch(/Merge epic\/gh-300 in and run the item's next step/);
});

test('FreeWorktreeWithASession_SaysTheSessionSitsThere', () => {
  renderWorktrees([{ ...poolWorktree('wt-10'), flags: ['session'], sessions: [claudeSession(62102, TWO_HOURS)] }]);
  const note = screen.getByText(/session sits here/);
  expect(note.textContent, 'because free next to a live session is confusing without naming it').toMatch(/claude.*pid 62102/);
});
