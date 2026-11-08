import { cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import type { Item, PullRequest } from '../../daemon/src/snapshot.ts';
import { Board, trackerNotRead } from '../src/screens/Board.tsx';
import { formatCost, formatTokens } from '../src/spend.ts';
import { boardItem, FakeDaemon, snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

afterEach(cleanup);

const SPENT: Item = { ...boardItem('gh#7', 'Seven'), state: 'running', spend: { costUsd: 1.234567, sessions: 3, tokens: 120000 } };
const CODEX: Item = { ...boardItem('gh#9', 'Nine'), spend: { costUsd: 0, sessions: 2, tokens: 50000 } };
const NOTHING: Item = boardItem('gh#12', 'Twelve');
const REVIEWED: Item = { ...boardItem('gh#20', 'Twenty'), state: 'in-review', step: 'done', pr: '20', spend: { costUsd: 0.5, sessions: 1, tokens: 9000 } };

function renderBoard(items: Item[], selected: string | null = null, pulls: PullRequest[] = []): void {
  const Wrapper = new FakeDaemon().screenWrapper();
  render(<Wrapper><Board snapshot={{ ...snapshotAt(TAKEN_AT, 0), items, pulls }} selected={selected} /></Wrapper>);
}

const row = (title: string): HTMLElement => screen.getByRole('link', { name: title }).closest('tr')!;

test('ItemWithSpend_ShowsItsCost', () => {
  renderBoard([SPENT, NOTHING]);
  expect(row('Seven').textContent, 'because the cost of an item must not stay invisible').toMatch(/\$1\.23/);
});

test('ItemWithoutSpend_ShowsNothingNotZero', () => {
  renderBoard([SPENT, NOTHING]);
  expect(row('Twelve').textContent, 'because no session is not the same as a free one').not.toMatch(/\$/);
});

test('CodexOnlyItem_ShowsTokensNotZeroDollars', () => {
  renderBoard([CODEX]);
  expect(row('Nine').textContent, 'because codex reports no cost, so $0.00 would mislead').toMatch(/50k tokens/);
});

test('HeadLine_TotalsTheItemsOnScreen', () => {
  renderBoard([SPENT, CODEX, NOTHING, REVIEWED]);
  expect(screen.getByLabelText('Spend shown').textContent, 'because the head line sums every item the filter shows').toBe('$1.73 on 3 items · 6 sessions · 179k tokens');
  fireEvent.click(screen.getByRole('button', { name: /^In review/ }));
  expect(screen.getByLabelText('Spend shown').textContent, 'because a filter narrows the total with the list').toBe('$0.50 on 1 item · 1 session · 9k tokens');
});

test('InReviewItem_ShowsInReviewNeverBlocked', () => {
  renderBoard([REVIEWED]);
  expect(row('Twenty').textContent, 'because an item whose PR waits on reviewers is not blocked').toMatch(/in review/);
  expect(row('Twenty').textContent).not.toMatch(/blocked/);
});

test('ClearedGate_AnswerWaitingOnTheCommentsJob_ShowsInRowAndDetail', () => {
  const answered: Item = { ...REVIEWED, answerPending: 'comments' };
  renderBoard([answered], 'gh#20');
  expect(row('Twenty').textContent, 'because a cleared gate whose answer no run took yet must not sit unseen').toMatch(/done · answer waits on the comments job/);
  expect(screen.getByText('Gate').nextElementSibling?.textContent, 'because the detail says the gate was cleared and what carries the answer out').toBe('cleared, answer waits on the comments job');
});

test('NoAnswerWaiting_RowShowsTheStepAlone', () => {
  renderBoard([REVIEWED]);
  expect(row('Twenty').textContent, 'because only an answer that waits on a run is named').not.toMatch(/answer waits/);
});

test('PickedItem_DetailShowsSessionsAndTokens', () => {
  renderBoard([SPENT], 'gh#7');
  const spend = screen.getByLabelText('Spend');
  expect(within(spend).getByText('3').tagName, 'because the detail says how many sessions the cost took').toBe('DD');
  expect(spend.textContent, 'because the tokens show in full in the detail').toMatch(/120,000/);
});

test('ItemWithoutPrField_PullMatchedByBranch_ShowsInPrColumn', () => {
  const pull: PullRequest = {
    number: 31, title: 'Seven', url: 'https://github.com/owner/project/pull/31', branch: 'flow/gh-7', base: 'main', author: 'owner', draft: false,
    state: 'checks-failing', checks: { passed: 1, failed: 1, pending: 0 }, checkRuns: [], head: null, autoMerge: null, changesRequested: 0, reviewsRequested: 0, reviewDecision: '', unresolvedThreads: 0, mergeable: 'MERGEABLE', mergeState: 'CLEAN',
    item: 'gh#7', worktree: 'p-wt-1', createdAt: TAKEN_AT, updatedAt: TAKEN_AT, ageSeconds: 60, idleSeconds: 60, review: null, quiz: null,
  };
  renderBoard([SPENT], null, [pull]);
  expect(within(row('Seven')).getByRole('link', { name: '#31' }), 'because a PR found by the claimed branch is still the item\'s PR').not.toBeNull();
});

test('Formats_CostAndTokens', () => {
  expect([formatCost(0.004), formatCost(12.3456), formatTokens(950), formatTokens(1234567)], 'because a cell must stay short and never round a real cost to $0.00').toEqual(['<$0.01', '$12.35', '950', '1.2M']);
});

test('TrackerNotRead_BannerSaysWhyItsItemsAreMissing', () => {
  const snapshot = snapshotAt(TAKEN_AT, 0);
  const project = { ...snapshot.project, trackers: [...snapshot.project.trackers, { name: 'jira', url: null, error: 'JIRA_API_TOKEN is not set' }] };
  const Wrapper = new FakeDaemon().screenWrapper();
  render(<Wrapper><Board snapshot={{ ...snapshot, project, items: [NOTHING] }} selected={null} /></Wrapper>);
  expect(screen.getAllByRole('alert').map((alert) => alert.textContent), 'because fewer items with no word would read as no work, while the owner can fix the cause').toEqual([trackerNotRead('jira', 'JIRA_API_TOKEN is not set')]);
});

test('EveryTrackerRead_NoBanner', () => {
  renderBoard([NOTHING]);
  expect(screen.queryByRole('alert'), 'because a board that read every tracker has nothing to warn about').toBeNull();
});
