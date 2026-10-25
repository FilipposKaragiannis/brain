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

test('Worktrees_EveryRow_OpenInTerminalOnItsPath', async () => {
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

test('BranchFarBehind_Clean_MergeButtonSyncsTheWorktree', async () => {
  const daemon = new FakeDaemon();
  const posted: unknown[] = [];
  daemon.answer('POST', ACTIONS_PATH, (body) => { posted.push(body); return { status: HTTP_ACCEPTED, body: { action: { ...actionRecord('s1', 'running', {}), kind: 'worktree.sync', args: { target: 'wt-7' } } } }; });
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><Worktrees snapshot={{ ...snapshotAt(TAKEN_AT, 0), worktrees: [BEHIND] }} /></Wrapper>);
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Merge epic/gh-300 in' })); });
  expect(posted, 'because the way out of a branch far behind is one press when nothing is in the way').toEqual([{ kind: 'worktree.sync', args: { target: 'wt-7' } }]);
});

test('BranchFarBehind_Dirty_SaysItInWordsWithNoButton', () => {
  renderWorktrees([{ ...BEHIND, dirtyFiles: 2 }]);
  expect(screen.queryByRole('button', { name: /Merge/ }), 'because the daemon refuses a merge over uncommitted files, so the button would only fail').toBeNull();
  expect(screen.getByText(/or release the worktree/).textContent, 'because the way out is still said').toMatch(/Merge epic\/gh-300 in/);
});

test('BranchFarBehind_RunRecord_NoMergeButton', () => {
  const Wrapper = new FakeDaemon().screenWrapper();
  const run = { item: 'gh#344', step: 'implement', profile: 'default', worktree: '/p-wt/wt-7', host: 'claude', startedAt: TAKEN_AT, alive: false };
  render(<Wrapper><Worktrees snapshot={{ ...snapshotAt(TAKEN_AT, 0), worktrees: [BEHIND], runs: [run] }} /></Wrapper>);
  expect(screen.queryByRole('button', { name: /Merge/ }), 'because a run record holds the item and the daemon would refuse').toBeNull();
});

const FILES = ['a.ts', 'b.ts', 'c.ts', 'd.ts', 'e.ts', 'f.ts', 'g.ts'];
const conflictedSync = (files: string[]) => ({ ...actionRecord('s9', 'failed', {}), kind: 'worktree.sync' as const, args: { target: 'wt-7' }, outcome: null, conflict: { refs: ['origin/flow/gh-344', 'origin/epic/gh-300'], files } });

/** The Worktrees screen with the daemon listing `records` as its recent actions. */
async function renderWithActions(worktrees: Worktree[], records: unknown[], extra: Partial<ReturnType<typeof snapshotAt>> = {}) {
  const daemon = new FakeDaemon();
  const posted: unknown[] = [];
  daemon.answer('GET', ACTIONS_PATH, () => ({ status: 200, body: { actions: records } }));
  daemon.answer('POST', ACTIONS_PATH, (body) => { posted.push(body); return { status: HTTP_ACCEPTED, body: { action: { ...actionRecord('h1', 'running', {}), kind: 'sync.handoff', args: { target: 'wt-7' } } } }; });
  const Wrapper = daemon.screenWrapper();
  await act(async () => { render(<Wrapper><Worktrees snapshot={{ ...snapshotAt(TAKEN_AT, 0), worktrees, ...extra }} /></Wrapper>); });
  return { posted };
}

test('SyncConflicted_ListsTheFilesFoldedAfterFive', async () => {
  await renderWithActions([BEHIND], [conflictedSync(FILES)]);
  const list = screen.getByRole('list', { name: 'Conflicting files' });
  expect(list.textContent, 'because the first five files say where the conflict is without burying the row').toBe('a.tsb.tsc.tsd.tse.ts');
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Show all 7 files' })); });
  expect(screen.getByRole('list', { name: 'Conflicting files' }).textContent, 'because every file is one press away').toMatch(/g\.ts$/);
});

test('SyncConflicted_HandToTheFlow_PostsTheHandoffWithTheRefs', async () => {
  const { posted } = await renderWithActions([BEHIND], [conflictedSync(['a.ts'])]);
  const button = screen.getByRole('button', { name: 'Hand to the flow' });
  expect(button.getAttribute('title'), 'because the owner must know the press starts a run').toBe("Writes the sync note and starts the item's run. The flow's sync step merges, resolves what it can, and raises an escalation gate if a choice is yours.");
  await act(async () => { fireEvent.click(button); });
  expect(posted, 'because the note names the refs the sync still had to merge, one per line').toEqual([{ kind: 'sync.handoff', args: { target: 'wt-7', refs: 'origin/flow/gh-344\norigin/epic/gh-300' } }]);
});

test('SyncConflicted_RunGoingAndNoteThere_SaysTheSyncRunsFirst', async () => {
  const run = { item: 'gh#344', step: 'sync', profile: 'default', worktree: '/p-wt/wt-7', host: 'claude', startedAt: TAKEN_AT, alive: true };
  await renderWithActions([{ ...BEHIND, syncPending: ['origin/epic/gh-300'] }], [conflictedSync(['a.ts'])], { runs: [run] });
  expect(screen.queryByRole('button', { name: 'Hand to the flow' }), 'because a second run would be refused while one goes').toBeNull();
  expect(screen.queryByText('A run is going; the sync step runs first when it starts'), 'because the note is already there for the run').not.toBeNull();
});

test('SyncPending_ShownOnTheCardWithoutAConflict', async () => {
  await renderWithActions([{ ...BEHIND, syncPending: ['origin/flow/gh-344', 'origin/main'] }], []);
  expect(screen.getByText(/sync pending:/).textContent, 'because a note the health job wrote must show too').toBe('sync pending: origin/flow/gh-344, origin/main');
  expect(screen.queryByRole('button', { name: 'Hand to the flow' }), 'because without a conflict there is nothing the console holds to hand on').toBeNull();
});

test('SyncConflicted_ThenACleanSync_ConflictGone', async () => {
  const clean = { ...actionRecord('s10', 'done', {}), kind: 'worktree.sync' as const, args: { target: 'gh#344' }, outcome: 'finished' as const, requestedAt: '2026-10-24T18:17:00Z' };
  await renderWithActions([BEHIND], [clean, conflictedSync(['a.ts'])]);
  expect(screen.queryByRole('list', { name: 'Conflicting files' }), 'because the last sync is the one that counts').toBeNull();
});

const handoff = { ...actionRecord('h2', 'done', {}), kind: 'sync.handoff' as const, args: { target: 'wt-7', refs: 'origin/flow/gh-344\norigin/epic/gh-300' }, outcome: 'started' as const, requestedAt: '2026-10-24T18:17:00Z', startedAt: '2026-10-24T18:17:00Z' };

test('SyncHandedOff_NoteNotReadYet_ConflictStaysAsHandingOff', async () => {
  await renderWithActions([BEHIND], [handoff, conflictedSync(['a.ts'])]);
  expect(screen.queryByRole('list', { name: 'Conflicting files' }), 'because the note is written but the files source has not read it, so nothing else would show the merge is owed').not.toBeNull();
  expect(screen.queryByText(/Handing off to the flow/), 'because the button was pressed and must not be offered again').not.toBeNull();
  expect(screen.queryByRole('button', { name: 'Hand to the flow' }), 'because a second hand-off would race the first').toBeNull();
});

test('SyncHandedOff_ReadSinceWithNoNote_ConflictGone', async () => {
  const snapshot = snapshotAt(TAKEN_AT, 0);
  const files = { ...snapshot.sources.files, at: '2026-10-24T18:30:00Z' };
  await renderWithActions([BEHIND], [handoff, conflictedSync(['a.ts'])], { sources: { ...snapshot.sources, files } });
  expect(screen.queryByRole('list', { name: 'Conflicting files' }), 'because a read after the hand-off found no note: the sync step merged and dropped it').toBeNull();
});
