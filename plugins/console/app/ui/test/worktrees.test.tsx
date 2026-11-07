import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import type { ActionRecord, Run, Worktree } from '../../daemon/src/snapshot.ts';
import { RELEASE_RESERVED_TITLE, Worktrees } from '../src/screens/Worktrees.tsx';
import { actionRecord, boardItem, claudeSession, FakeDaemon, HTTP_ACCEPTED, HTTP_CONFLICT, poolWorktree, readyToClose, snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

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

test('OutsideWorktree_NotAPoolCard', () => {
  renderWorktrees([poolWorktree('wt-2'), { ...poolWorktree('elsewhere'), role: 'outside', state: 'outside' }]);
  expect(screen.getByRole('region', { name: 'Pool' }).textContent, 'because the pool cards show only what the flow can claim').not.toMatch(/elsewhere/);
});

test('SessionsOnACard_ExplainTheWordOnHover', () => {
  renderWorktrees([{ ...poolWorktree('wt-10'), flags: ['session'], sessions: [claudeSession(62102, TWO_HOURS)] }]);
  expect(screen.getByText('sessions').parentElement?.getAttribute('title'), 'because a session is not an agent and the card must say so').toMatch(/not an agent/i);
});

test('Filter_Stale_ShowsOnlyTheStaleCards', () => {
  renderWorktrees([poolWorktree('wt-2'), { ...poolWorktree('wt-7'), state: 'stale', item: 'gh#344', staleReason: 'branch is behind' }]);
  fireEvent.click(screen.getByRole('button', { name: /^Stale/ }));
  expect(screen.getAllByRole('article').map((card) => card.getAttribute('aria-label')), 'because the filter narrows the pool to the cards in that state').toEqual(['wt-7']);
});

test('Filter_CountsEachState', () => {
  renderWorktrees([poolWorktree('wt-2'), poolWorktree('wt-3'), { ...poolWorktree('wt-7'), state: 'stale' }]);
  expect(screen.getByRole('button', { name: /^Free/ }).textContent, 'because each chip says how many cards it would show').toMatch(/2$/);
});

test('RunningCard_WatchLeadsToAgents', () => {
  renderWorktrees([{ ...poolWorktree('wt-10'), state: 'running', item: 'gh#213' }]);
  expect(screen.getByRole('link', { name: 'Watch' }).getAttribute('href'), 'because a running card is followed on the Agents screen').toBe('#/project/agents');
});

test('WaitingCard_DecideLeadsToItsGate', () => {
  renderWorktrees([{ ...poolWorktree('wt-3'), state: 'needs-you', item: 'gh#322' }]);
  expect(screen.getByRole('link', { name: 'Decide' }).getAttribute('href'), 'because a card waiting on you opens the gate it waits at').toBe('#/project/gates/gh%23322');
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

const CLAIM = { item: 'gh#344', branch: 'flow/gh-344', base: 'epic/gh-300', step: 'implement', claimedAt: TAKEN_AT, host: 'claude', reserved: '' };

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
  const run: Run = { item: 'gh#344', step: 'implement', profile: 'default', worktree: '/p-wt/wt-7', host: 'claude', startedAt: TAKEN_AT, pid: null, liveness: 'dead' };
  render(<Wrapper><Worktrees snapshot={{ ...snapshotAt(TAKEN_AT, 0), worktrees: [BEHIND], runs: [run] }} /></Wrapper>);
  expect(screen.queryByRole('button', { name: /Merge/ }), 'because a run record holds the item and the daemon would refuse').toBeNull();
});

test('RunWhoseProcessIsUnknown_CardSaysTheProcessListIsIncomplete', () => {
  const Wrapper = new FakeDaemon().screenWrapper();
  const run: Run = { item: 'gh#344', step: 'implement', profile: 'default', worktree: '/p-wt/wt-7', host: 'claude', startedAt: TAKEN_AT, pid: 19487, liveness: 'unknown' };
  const processList = { status: 'partial' as const, reason: 'lsof timed out after 10s; no working directory for pid 23465', unplaced: [23465], lookup: { command: 'lsof' as const, code: null, timedOut: true, durationMs: 10002, stderr: '' } };
  render(<Wrapper><Worktrees snapshot={{ ...snapshotAt(TAKEN_AT, 0), worktrees: [{ ...BEHIND, state: 'running', flags: [] }], runs: [run], processList }} /></Wrapper>);
  expect(screen.getByText(/may still go/).textContent, 'because the card says why the run is not shown dead').toMatch(/process list incomplete: lsof timed out after 10s; no working directory for pid 23465/);
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
  const run: Run = { item: 'gh#344', step: 'sync', profile: 'default', worktree: '/p-wt/wt-7', host: 'claude', startedAt: TAKEN_AT, pid: null, liveness: 'alive' };
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

/** The Worktrees screen over one free worktree, with the daemon answering every action with `answer`. */
async function pressToolbar(label: string, answer: ActionRecord) {
  const daemon = new FakeDaemon();
  const posted: unknown[] = [];
  daemon.answer('POST', ACTIONS_PATH, (body) => { posted.push(body); return { status: HTTP_ACCEPTED, body: { action: answer } }; });
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><Worktrees snapshot={{ ...snapshotAt(TAKEN_AT, 0), worktrees: [poolWorktree('wt-2')] }} /></Wrapper>);
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: label })); });
  return { posted };
}

test('Toolbar_Sweep_PostsASweep', async () => {
  const { posted } = await pressToolbar('Sweep', { ...actionRecord('w1', 'running', {}), kind: 'steward.sweep' });
  expect(posted, 'because Sweep runs the steward sweep now, not on the next schedule').toEqual([{ kind: 'steward.sweep', args: {} }]);
});

test('Toolbar_SweepDone_ShowsWhatItFreed', async () => {
  await pressToolbar('Sweep', { ...actionRecord('w2', 'done', {}), kind: 'steward.sweep', outcome: 'finished', note: 'freed wt-3 (gh#41); cleared the merge gate of gh#41' });
  expect(screen.queryByText('freed wt-3 (gh#41); cleared the merge gate of gh#41'), 'because the owner pressed Sweep to see what landed').not.toBeNull();
});

const RESERVED: Worktree = { ...poolWorktree('wt-4'), state: 'claimed', claim: { ...CLAIM, item: '', branch: '', step: '', reserved: 'Ada Lovelace' } };

test('ReservedCard_SaysWhoReservedIt', () => {
  renderWorktrees([RESERVED]);
  expect(screen.queryByText('reserved by Ada Lovelace'), 'because a claim with no item would otherwise read as a stray one').not.toBeNull();
});

test('ReservedCard_HasRelease', async () => {
  const daemon = new FakeDaemon();
  const posted: unknown[] = [];
  daemon.answer('POST', ACTIONS_PATH, (body) => { posted.push(body); return { status: HTTP_ACCEPTED, body: { action: { ...actionRecord('l1', 'running', {}), kind: 'worktree.release', args: { target: 'wt-4' } } } }; });
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><Worktrees snapshot={{ ...snapshotAt(TAKEN_AT, 0), worktrees: [RESERVED] }} /></Wrapper>);
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Release' })); });
  expect(posted, 'because the owner frees a reservation the way any claim is freed').toEqual([{ kind: 'worktree.release', args: { target: 'wt-4' } }]);
});

/** The Worktrees screen over `worktrees`, with the daemon answering a press on `name`'s Reserve with `answer`. */
async function pressReserve(worktrees: Worktree[], name: string, answer: ActionRecord) {
  const daemon = new FakeDaemon();
  const posted: unknown[] = [];
  daemon.answer('POST', ACTIONS_PATH, (body) => { posted.push(body); return { status: HTTP_ACCEPTED, body: { action: answer } }; });
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><Worktrees snapshot={{ ...snapshotAt(TAKEN_AT, 0), worktrees }} /></Wrapper>);
  await act(async () => { fireEvent.click(within(screen.getByRole('article', { name })).getByRole('button', { name: 'Reserve' })); });
  return { posted };
}

const reserving = (id: string, state: ActionRecord['state'], target: string): ActionRecord => ({ ...actionRecord(id, state, {}), kind: 'worktree.reserve', args: { target } });

test('Toolbar_HasNoReserve', () => {
  renderWorktrees([RESERVED, { ...poolWorktree('wt-2'), state: 'claimed', claim: CLAIM, item: 'gh#344' }]);
  expect(screen.queryByRole('button', { name: 'Reserve' }), 'because Reserve sits on each free card, so the owner picks the worktree they get').toBeNull();
});

test('FreeCard_Reserve_PostsAReserveOfThatWorktree', async () => {
  const { posted } = await pressReserve([poolWorktree('wt-2'), poolWorktree('wt-3')], 'wt-3', reserving('r1', 'running', 'wt-3'));
  expect(posted, "because the card's Reserve takes that worktree, not the first free one").toEqual([{ kind: 'worktree.reserve', args: { target: 'wt-3' } }]);
});

test('FreeCard_EveryOneHasReserve', () => {
  renderWorktrees([poolWorktree('wt-2'), poolWorktree('wt-3')]);
  expect(screen.getAllByRole('article').map((card) => within(card).queryByRole('button', { name: 'Reserve' }) !== null), 'because any free worktree can be the one the owner takes').toEqual([true, true]);
});

test('FreeCard_ReserveRunning_ShowsOnThatCardOnly', async () => {
  await pressReserve([poolWorktree('wt-2'), poolWorktree('wt-3')], 'wt-3', reserving('r2', 'running', 'wt-3'));
  expect((within(screen.getByRole('article', { name: 'wt-3' })).getByRole('button', { name: 'Reserve…' }) as HTMLButtonElement).disabled, 'because the pressed card waits for its own reserve').toBe(true);
  expect((within(screen.getByRole('article', { name: 'wt-2' })).getByRole('button', { name: 'Reserve' }) as HTMLButtonElement).disabled, 'because a reserve of another worktree does not hold this one').toBe(false);
});

test('FreeCard_ReserveFailed_ShowsTheOutcomeOnThatCard', async () => {
  await pressReserve([poolWorktree('wt-2'), poolWorktree('wt-3')], 'wt-3', reserving('r3', 'failed', 'wt-3'));
  expect(within(screen.getByRole('article', { name: 'wt-3' })).queryByText('failed (exit 1)'), 'because the owner sees on the card they pressed that the steward refused it').not.toBeNull();
  expect(within(screen.getByRole('article', { name: 'wt-2' })).queryByText('failed (exit 1)'), 'because the other card was not pressed').toBeNull();
});

test('ReservedCard_ReleaseInPlaceOfReserve', () => {
  renderWorktrees([RESERVED]);
  const card = screen.getByRole('article', { name: 'wt-4' });
  expect(within(card).queryByRole('button', { name: 'Reserve' }), 'because a reserved worktree is no longer free to take').toBeNull();
  expect(within(card).getByRole('button', { name: 'Release' }).getAttribute('title'), "because the button gives back the owner's own reservation, not a flow claim").toBe(RELEASE_RESERVED_TITLE);
});

test('ClaimedCard_ReleaseAndNoReserve', () => {
  renderWorktrees([{ ...poolWorktree('wt-2'), state: 'claimed', claim: CLAIM, item: 'gh#344' }]);
  const card = screen.getByRole('article', { name: 'wt-2' });
  expect([within(card).queryByRole('button', { name: 'Reserve' }), within(card).queryByRole('button', { name: 'Release' }) !== null], 'because a worktree the flow holds is released, never reserved').toEqual([null, true]);
});

/** A free wt-3 card whose Reserve the daemon answers with `answer`, and a way to show the screen over other worktrees afterwards. */
async function pressReserveThenRefresh(answer: { status: number; body: unknown }) {
  const daemon = new FakeDaemon();
  daemon.answer('POST', ACTIONS_PATH, () => answer);
  const Wrapper = daemon.screenWrapper();
  const view = (worktrees: Worktree[]) => <Wrapper><Worktrees snapshot={{ ...snapshotAt(TAKEN_AT, 0), worktrees }} /></Wrapper>;
  const rendered = render(view([poolWorktree('wt-3')]));
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Reserve' })); });
  return { refresh: (worktrees: Worktree[]) => rendered.rerender(view(worktrees)) };
}

const RESERVED_WT3: Worktree = { ...RESERVED, name: 'wt-3' };

test('FreeCard_ReserveRefused_RefusalStaysWhenTheCardTurnsToRelease', async () => {
  const { refresh } = await pressReserveThenRefresh({ status: HTTP_CONFLICT, body: { error: 'wt-3 is already claimed' } });
  refresh([RESERVED_WT3]);
  const card = screen.getByRole('article', { name: 'wt-3' });
  expect([within(card).queryByRole('button', { name: 'Release' }) !== null, within(card).queryByText('wt-3 is already claimed') !== null], 'because the refresh that turns the card to Release must not hide why the reserve was refused').toEqual([true, true]);
});

test('FreeCard_ReserveEnded_OutcomeStaysWhenTheCardTurnsToRelease', async () => {
  const { refresh } = await pressReserveThenRefresh({ status: HTTP_ACCEPTED, body: { action: reserving('r4', 'failed', 'wt-3') } });
  refresh([RESERVED_WT3]);
  expect(within(screen.getByRole('article', { name: 'wt-3' })).queryByText('failed (exit 1)'), "because the reserve's outcome belongs to the card, not to the Reserve button").not.toBeNull();
});

const PARKED: Worktree = { ...poolWorktree('wt-5'), state: 'waiting', item: 'gh#30', claim: { item: 'gh#30', branch: 'flow/gh-30', base: 'main', step: 'implement', claimedAt: TAKEN_AT, host: 'claude', reserved: '' } };
const HELD_CARD: Worktree = { ...PARKED, name: 'wt-6', state: 'held', item: 'gh#31', heldBy: 'gh#12', heldReason: 'shares src/board.ts, which gh#12 changes' };

test('WaitingCard_SaysItWaitsForAWorkerAndTheNextStep', () => {
  renderWorktrees([PARKED]);
  const card = screen.getByRole('article', { name: 'wt-5' });
  expect(card.textContent, 'because a claim with no run must not read as work going on').toMatch(/Waiting for a worker.*runs implement here/);
  expect(within(card).queryByText('next step'), 'because the step shown is the one a worker takes next').not.toBeNull();
});

test('HeldCard_NamesItsHolderLinkedAndWhy', () => {
  const Wrapper = new FakeDaemon().screenWrapper();
  render(<Wrapper><Worktrees snapshot={{ ...snapshotAt(TAKEN_AT, 0), worktrees: [HELD_CARD], items: [boardItem('gh#12', 'Twelve')] }} /></Wrapper>);
  const card = screen.getByRole('article', { name: 'wt-6' });
  expect(within(card).getByRole('link', { name: 'gh#12' }).getAttribute('href'), 'because the owner opens what it waits behind').toBe('https://github.com/owner/project/issues/12');
  expect(card.textContent, 'because the card says why, and when it moves again').toMatch(/Held behind gh#12: shares src\/board\.ts, which gh#12 changes\. The next job skips it until gh#12 closes, then runs implement\./);
});

test('Filters_WaitingAndHeldCountedApart', () => {
  renderWorktrees([PARKED, HELD_CARD, poolWorktree('wt-2')]);
  expect([screen.getByRole('button', { name: /^Waiting/ }).textContent, screen.getByRole('button', { name: /^Held/ }).textContent], 'because waiting for a worker and held behind another item are different waits').toEqual(['Waiting 1', 'Held 1']);
});

test('NothingHeld_NoHeldFilter', () => {
  renderWorktrees([PARKED]);
  expect(screen.queryByRole('button', { name: /^Held/ }), 'because a chip for a state no card is in is noise').toBeNull();
});

test('ItemToCloseOnACard_SaysWhatToDoAndDecideOpensIt', () => {
  const done: Worktree = { ...PARKED, name: 'wt-8', state: 'needs-you', item: 'gh#40' };
  const Wrapper = new FakeDaemon().screenWrapper();
  render(<Wrapper><Worktrees snapshot={{ ...snapshotAt(TAKEN_AT, 1), worktrees: [done], toClose: [{ ...readyToClose('gh#40', 'steps-done'), worktree: 'wt-8' }] }} /></Wrapper>);
  expect(screen.getByRole('article', { name: 'wt-8' }).textContent, 'because no gate explains why it needs you').toMatch(/Ready to close, though no gate asks\. Every step ran: merge or close\./);
  expect(screen.getByRole('link', { name: 'Decide' }).getAttribute('href'), 'because the Gates screen lists it').toBe('#/project/gates/gh%2340');
});
