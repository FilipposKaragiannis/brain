import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import type { Worktree } from '../../daemon/src/snapshot.ts';
import { Worktrees } from '../src/screens/Worktrees.tsx';
import { actionRecord, claudeSession, FakeDaemon, HTTP_ACCEPTED, poolWorktree, snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

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

const ACTIONS_PATH = '/api/projects/project/actions';

test('EveryWorktree_OpenInTerminalOnItsPath', async () => {
  const daemon = new FakeDaemon();
  const posted: unknown[] = [];
  daemon.answer('POST', ACTIONS_PATH, (body) => { posted.push(body); return { status: HTTP_ACCEPTED, body: { action: { ...actionRecord('t1', 'done', {}), kind: 'terminal.open', args: { path: '/p' }, outcome: 'finished' } } }; });
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><Worktrees snapshot={{ ...snapshotAt(TAKEN_AT, 0), worktrees: [poolWorktree('wt-2'), { ...poolWorktree('project'), path: '/p', role: 'main', state: 'outside' }] }} /></Wrapper>);
  const buttons = screen.getAllByRole('button', { name: 'Open in Terminal' });
  expect(buttons.length, 'because the pool rows and the project root outside it each open a terminal').toBe(2);
  await act(async () => { fireEvent.click(buttons[1]!); });
  expect(posted, 'because the button opens the folder the row shows').toEqual([{ kind: 'terminal.open', args: { path: '/p' } }]);
  expect(screen.getByText('done'), 'because the button shows how its action ended, as every action button does').not.toBeNull();
});

const BEHIND: Worktree = { ...poolWorktree('wt-7'), state: 'stale', flags: ['stale-branch'], claim: CLAIM, item: 'gh#344', staleReason: 'branch is 27 commits behind epic/gh-300 (limit 20)' };

test('BranchFarBehindAndClean_MergeButtonSyncsTheWorktree', async () => {
  const daemon = new FakeDaemon();
  const posted: unknown[] = [];
  daemon.answer('POST', ACTIONS_PATH, (body) => { posted.push(body); return { status: HTTP_ACCEPTED, body: { action: { ...actionRecord('s1', 'running', {}), kind: 'worktree.sync', args: { target: 'wt-7' } } } }; });
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><Worktrees snapshot={{ ...snapshotAt(TAKEN_AT, 0), worktrees: [BEHIND] }} /></Wrapper>);
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Merge epic/gh-300 in' })); });
  expect(posted, 'because the way out of a branch far behind is one press when nothing is in the way').toEqual([{ kind: 'worktree.sync', args: { target: 'wt-7' } }]);
});

test('BranchFarBehindButDirty_SaysItInWordsWithNoButton', () => {
  renderWorktrees([{ ...BEHIND, dirtyFiles: 2 }]);
  expect(screen.queryByRole('button', { name: /Merge/ }), 'because the daemon refuses a merge over uncommitted files, so the button would only fail').toBeNull();
  expect(screen.getByText(/or release the worktree/).textContent, 'because the way out is still said').toMatch(/Merge epic\/gh-300 in/);
});

test('BranchFarBehindWithARunRecord_NoMergeButton', () => {
  const Wrapper = new FakeDaemon().screenWrapper();
  const run = { item: 'gh#344', step: 'implement', profile: 'default', worktree: '/p-wt/wt-7', host: 'claude', startedAt: TAKEN_AT, alive: false };
  render(<Wrapper><Worktrees snapshot={{ ...snapshotAt(TAKEN_AT, 0), worktrees: [BEHIND], runs: [run] }} /></Wrapper>);
  expect(screen.queryByRole('button', { name: /Merge/ }), 'because a run record holds the item and the daemon would refuse').toBeNull();
});
