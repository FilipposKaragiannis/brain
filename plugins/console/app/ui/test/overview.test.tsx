import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import type { AttentionRow, Disagreement, PullRequest, Snapshot } from '../../daemon/src/snapshot.ts';
import type { Route } from '../src/route.ts';
import { Overview, tiles } from '../src/screens/Overview.tsx';
import { FIELD_ROWS_SHOWN } from '../src/screens/NeedsYou.tsx';
import { actionRecord, boardDisagreement, readiness, boardItem, FakeDaemon, HTTP_ACCEPTED, poolWorktree, snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

afterEach(cleanup);

const ignoreRoute = (): void => {};

function renderOverview(snapshot: Snapshot, go: (route: Route) => void = ignoreRoute): void {
  const Wrapper = new FakeDaemon().screenWrapper();
  render(<Wrapper><Overview snapshot={snapshot} go={go} /></Wrapper>);
}

function failingPull(number: number): PullRequest {
  return {
    number, title: `PR ${number}`, url: `https://github.com/owner/project/pull/${number}`, branch: `b${number}`, base: 'main', author: 'o', draft: false, state: 'checks-failing',
    checks: { passed: 0, failed: 1, pending: 0 }, reviewDecision: null, unresolvedThreads: 0, mergeable: null, item: null, worktree: null,
    createdAt: TAKEN_AT, updatedAt: TAKEN_AT, ageSeconds: 0, idleSeconds: 0, review: null, quiz: null,
  };
}

function gateRow(id: string, ageSeconds: number): AttentionRow {
  return { kind: 'gate', id, title: `Plan for ${id}`, detail: 'plan', worktree: null, sinceAt: TAKEN_AT, ageSeconds, action: null };
}

function needsField(id: string): AttentionRow {
  return { kind: 'needs-field', id, title: `Item ${id}`, detail: 'needs priority', worktree: null, sinceAt: null, ageSeconds: null, action: null };
}

test('ClaimedPoolCell_ShowsTheItemTitle', () => {
  const claimed = { ...poolWorktree('wt-2'), state: 'claimed' as const, item: 'gh#268', itemTitle: 'Preset retune: re-arm the ladder' };
  renderOverview({ ...snapshotAt(TAKEN_AT, 0), worktrees: [claimed] });
  expect(screen.queryByText('Preset retune: re-arm the ladder'), 'because an id alone does not say what the worktree works on').not.toBeNull();
});

test('ReadinessLine_SaysWhyNothingRuns', () => {
  renderOverview({ ...snapshotAt(TAKEN_AT, 0), readiness: readiness({ waitingOnField: 9, nextInLineMissingField: 4, gated: 5, blocked: 12 }) });
  expect(screen.getByLabelText('Readiness').textContent, 'because the tiles alone do not say why the pool is idle').toMatch(/4 items that are next in line lack a field/);
});

test('ItemWaitingOnAField_ListedWithTheFieldNamed', () => {
  renderOverview({ ...snapshotAt(TAKEN_AT, 0), attention: [needsField('gh#197')] });
  const row = screen.getByText('gh#197').closest('li');
  expect(row?.textContent, 'because the owner must see which field to fill on which item').toMatch(/needs priority/);
});

test('ItemWaitingOnAField_LinksToTheTracker', () => {
  const snapshot = { ...snapshotAt(TAKEN_AT, 0), attention: [needsField('gh#197')], items: [boardItem('gh#197', 'Rod dynamics')] };
  renderOverview(snapshot);
  expect(screen.getByRole('link', { name: 'gh#197' }).getAttribute('href'), 'because the field is filled in on the tracker').toBe('https://github.com/owner/project/issues/197');
});

test('ManyItemsWaitingOnAField_FoldAfterAFew', () => {
  const rows = ['gh#1', 'gh#2', 'gh#3', 'gh#4', 'gh#5', 'gh#6', 'gh#7'].map(needsField);
  renderOverview({ ...snapshotAt(TAKEN_AT, 0), attention: rows });
  expect(screen.getAllByText('needs priority').length, 'because a backlog without priorities must not bury the gates').toBe(FIELD_ROWS_SHOWN);
});

test('ShowAllPressed_ListsEveryItemWaitingOnAField', () => {
  const rows = ['gh#1', 'gh#2', 'gh#3', 'gh#4', 'gh#5', 'gh#6', 'gh#7'].map(needsField);
  renderOverview({ ...snapshotAt(TAKEN_AT, 0), attention: rows });
  fireEvent.click(screen.getByRole('button', { name: /show all 7/i }));
  expect(screen.getAllByText('needs priority').length, 'because the fold hides rows, it does not drop them').toBe(rows.length);
});

test('Disagreement_ShowsWhatEachStoreSays', () => {
  const disagreement = boardDisagreement('gh#310');
  renderOverview({ ...snapshotAt(TAKEN_AT, 0), disagreements: [disagreement] });
  expect(screen.queryByText(disagreement.explain), 'because a disagreement must say which store is usually right').not.toBeNull();
});

test('DisagreementWithAnAction_OffersItsButton', () => {
  renderOverview({ ...snapshotAt(TAKEN_AT, 0), disagreements: [boardDisagreement('gh#310')] });
  expect(screen.queryByRole('button', { name: 'Re-read the board' }), 'because the fix is one press away when the daemon knows it').not.toBeNull();
});

test('DisagreementWithoutAnAction_OffersNoButton', () => {
  renderOverview({ ...snapshotAt(TAKEN_AT, 0), disagreements: [{ ...boardDisagreement('gh#310'), action: null }] });
  const module = screen.getByRole('heading', { name: 'Disagreements' }).closest('section');
  expect(within(module as HTMLElement).queryByRole('button'), 'because a disagreement only a person can settle has nothing to press').toBeNull();
});

const STEP_MISMATCH: Disagreement = {
  item: 'gh#9', worktree: 'wt-3', sources: ['claim', 'issue state'], message: 'gh#9: the claim says step review, the issue says implement.',
  explain: "The claim in wt-3 says gh#9 is at step review, while the issue says implement; the claim is usually right, because it is the agent's own record and is written first, and the button writes step review to the issue as the flow does at a step change.",
  action: { kind: 'item.step-sync', args: { item: 'gh#9' }, label: "Set the issue's step to the claim's" },
};

test('StepMismatch_ButtonSetsTheIssuesStep', async () => {
  const daemon = new FakeDaemon();
  const posted: unknown[] = [];
  daemon.answer('POST', '/api/projects/project/actions', (body) => { posted.push(body); return { status: HTTP_ACCEPTED, body: { action: { ...actionRecord('s1', 'done', {}), kind: 'item.step-sync', args: { item: 'gh#9' }, outcome: 'finished' } } }; });
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><Overview snapshot={{ ...snapshotAt(TAKEN_AT, 0), disagreements: [STEP_MISMATCH] }} go={ignoreRoute} /></Wrapper>);
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: "Set the issue's step to the claim's" })); });
  expect(posted, "because the button writes the claim's step to that item's issue").toEqual([{ kind: 'item.step-sync', args: { item: 'gh#9' } }]);
});

test('Activity_ShowAllLeadsToTheActivityScreen', () => {
  renderOverview(snapshotAt(TAKEN_AT, 0));
  expect(screen.getByRole('link', { name: 'Show all' }).getAttribute('href'), 'because the overview shows only the latest events').toBe('#/project/activity');
});

test('StoppedHostRow_CarriesItsClearButton', () => {
  const stopped: AttentionRow = { kind: 'host-stopped', id: 'codex', title: 'codex is stopped', detail: 'usage limit', worktree: null, sinceAt: TAKEN_AT, ageSeconds: 60, action: { kind: 'host.clear', args: { host: 'codex' }, label: 'Clear codex' } };
  renderOverview({ ...snapshotAt(TAKEN_AT, 1), attention: [stopped] });
  expect(screen.queryByRole('button', { name: 'Clear codex' }), 'because the row is settled from where it is seen').not.toBeNull();
});

test('Tiles_NeedsYou_NamesTheOldestRowAndItsAge', () => {
  const needsYou = tiles({ ...snapshotAt(TAKEN_AT, 2), attention: [gateRow('gh#1', 600), gateRow('gh#2', 7200)] })[0]!;
  expect(needsYou.sub, 'because the oldest wait is the one to settle first').toMatch(/^oldest 2h.* · gh#2$/);
});

test('Tiles_ChecksRed_NamesTheFailingPullsAndLeadsToPulls', () => {
  const red = tiles({ ...snapshotAt(TAKEN_AT, 0), pulls: [failingPull(81), failingPull(82)] }).find((tile) => tile.label === 'Checks red')!;
  expect([red.sub, red.screen], 'because the owner fixes a red PR from the pulls screen').toEqual(['PR #81, PR #82', 'pulls']);
});

test('GateRow_DecideOpensThatGate', () => {
  const routes: Route[] = [];
  renderOverview({ ...snapshotAt(TAKEN_AT, 1), attention: [gateRow('gh#322', 600)] }, (route) => routes.push(route));
  fireEvent.click(screen.getByRole('button', { name: 'Decide' }));
  expect(routes, 'because a gate is settled on its own page').toEqual([{ projectId: 'project', screen: 'gates', detail: 'gh#322' }]);
});

test('NothingRuns_RunningNowSaysSo', () => {
  renderOverview(snapshotAt(TAKEN_AT, 0));
  expect(screen.queryByText('No run is going.'), 'because an empty panel would look like a broken one').not.toBeNull();
});
