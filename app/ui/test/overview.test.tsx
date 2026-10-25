import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import type { AttentionRow, Snapshot } from '../../daemon/src/snapshot.ts';
import { Overview } from '../src/screens/Overview.tsx';
import { FIELD_ROWS_SHOWN } from '../src/screens/NeedsYou.tsx';
import { boardDisagreement, boardItem, FakeDaemon, poolWorktree, snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

afterEach(cleanup);

const ignoreRoute = (): void => {};

function renderOverview(snapshot: Snapshot): void {
  const Wrapper = new FakeDaemon().screenWrapper();
  render(<Wrapper><Overview snapshot={snapshot} go={ignoreRoute} /></Wrapper>);
}

function needsField(id: string): AttentionRow {
  return { kind: 'needs-field', id, title: `Item ${id}`, detail: 'needs priority', worktree: null, sinceAt: null, ageSeconds: null };
}

test('ClaimedPoolCell_ShowsTheItemTitle', () => {
  const claimed = { ...poolWorktree('wt-2'), state: 'claimed' as const, item: 'gh#268', itemTitle: 'Preset retune: re-arm the ladder' };
  renderOverview({ ...snapshotAt(TAKEN_AT, 0), worktrees: [claimed] });
  expect(screen.queryByTitle('Preset retune: re-arm the ladder'), 'because an id alone does not say what the worktree works on').not.toBeNull();
});

test('ReadinessLine_SaysWhyNothingRuns', () => {
  renderOverview({ ...snapshotAt(TAKEN_AT, 0), readiness: { ready: 0, waitingOnField: 4, gated: 5, blocked: 12 } });
  expect(screen.getByLabelText('Readiness').textContent, 'because the tiles alone do not say why the pool is idle').toMatch(/4 items wait on a field/);
});

test('ItemWaitingOnAField_ListedWithTheFieldNamed', () => {
  renderOverview({ ...snapshotAt(TAKEN_AT, 0), attention: [needsField('gh#197')] });
  const row = screen.getByText('gh#197').closest('tr');
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

test('Activity_ShowAllLeadsToTheActivityScreen', () => {
  renderOverview(snapshotAt(TAKEN_AT, 0));
  expect(screen.getByRole('link', { name: 'Show all' }).getAttribute('href'), 'because the overview shows only the latest events').toBe('#/project/activity');
});
