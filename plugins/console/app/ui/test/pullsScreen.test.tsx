import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import type { PullRequest } from '../../daemon/src/snapshot.ts';
import { Pulls } from '../src/screens/Pulls.tsx';
import { actionRecord, FakeDaemon, HTTP_ACCEPTED, snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

afterEach(cleanup);

function pull(number: number, change: Partial<PullRequest>): PullRequest {
  return {
    number, title: `Pull ${number}`, url: `https://github.com/owner/project/pull/${number}`, branch: `flow/gh-${number}`, base: 'main', author: 'owner',
    draft: false, state: 'mergeable', checks: { passed: 5, failed: 0, pending: 0 }, reviewDecision: 'APPROVED', unresolvedThreads: 0, mergeable: 'MERGEABLE', mergeState: 'CLEAN',
    item: null, worktree: null, createdAt: TAKEN_AT, updatedAt: TAKEN_AT, ageSeconds: 3600, idleSeconds: 600, review: null, quiz: null, ...change,
  };
}

function renderPulls(pulls: PullRequest[], daemon = new FakeDaemon()): void {
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><Pulls snapshot={{ ...snapshotAt(TAKEN_AT, 0), pulls }} /></Wrapper>);
}

const card = (number: number): HTMLElement => screen.getByRole('region', { name: `PR #${number}` });

test('InReviewPull_SaysWhoItWaitsOnAndOffersNoMerge', () => {
  renderPulls([pull(20, { state: 'in-review', review: { state: 'in-review', waiting: ['codex'], cannot: [], at: TAKEN_AT } })]);
  expect(card(20).textContent, 'because the pull waits on a reviewer asked by a mention').toMatch(/in review/);
  expect(card(20).textContent, 'because the owner sees who it waits on').toMatch(/waiting on codex/);
  expect(within(card(20)).queryByRole('button', { name: 'Merge' }), 'because a pull still in review is not the owner\'s to merge yet').toBeNull();
  expect(card(20).textContent, 'because the card says why there is no merge').toMatch(/Merge waits on codex/);
});

test('ReviewerCannot_ReplyShownWithTheWayOut', () => {
  renderPulls([pull(20, { review: { state: 'ready', waiting: [], cannot: [{ reviewer: 'codex', said: 'Create an environment for this repo.' }], at: TAKEN_AT } })]);
  const reviewers = within(card(20)).getByRole('list', { name: 'Reviewers' });
  expect(reviewers.textContent, 'because the reviewer\'s own reply says what is missing').toMatch(/Create an environment for this repo\./);
  expect(reviewers.textContent, 'because the owner learns the PR goes on without that review, and how to fix it').toMatch(/The PR waits without that review\. Set codex up for this repository, or drop it from reviews\.reviewers/);
  expect(card(20).textContent, 'because the review cell leads with the reviewer that cannot review').toMatch(/codex cannot review/);
});

test('MergeablePull_MergeButton', () => {
  renderPulls([pull(21, {})]);
  expect(within(card(21)).queryByRole('button', { name: 'Merge' }), 'because a ready pull is merged from its card').not.toBeNull();
  expect(card(21).textContent, 'because the health strip says the checks are green').toMatch(/all 5 passed/);
});

test('FailingPull_NoMergeAndTheReason', () => {
  renderPulls([pull(22, { state: 'checks-failing', checks: { passed: 3, failed: 2, pending: 0 } })]);
  expect(within(card(22)).queryByRole('button', { name: 'Merge' }), 'because failing checks must not be merged from a button').toBeNull();
  expect(card(22).textContent, 'because the card says what holds the merge').toMatch(/Merge is off while checks fail\./);
});

test('Summary_CountsOpenInReviewAndReady', () => {
  renderPulls([pull(20, { state: 'in-review', review: { state: 'in-review', waiting: ['codex'], cannot: [], at: TAKEN_AT } }), pull(21, {})]);
  expect(screen.getByLabelText('Summary').textContent, 'because the head line says where the open pulls stand').toMatch(/2 open · 1 in review · 1 ready to merge/);
});

function recordingDaemon(): { daemon: FakeDaemon; posted: Array<{ kind: string; args: Record<string, string> }> } {
  const daemon = new FakeDaemon();
  const posted: Array<{ kind: string; args: Record<string, string> }> = [];
  daemon.answer('POST', '/api/projects/project/actions', (body) => {
    const action = body as { kind: 'pr.review' | 'pr.merge' | 'job.start'; args: Record<string, string> };
    posted.push(action);
    return { status: HTTP_ACCEPTED, body: { action: { ...actionRecord(`a${posted.length}`, 'running', action.args), kind: action.kind } } };
  });
  return { daemon, posted };
}

test('AskForReview_PickedReviewer_PostsPrReview', async () => {
  const { daemon, posted } = recordingDaemon();
  renderPulls([pull(20, {})], daemon);
  const ask = within(card(20)).getByLabelText('Ask for review from');
  expect([...(ask as HTMLSelectElement).options].map((option) => option.value).slice(0, 2), 'because the list is the project\'s reviews.reviewers').toEqual(['codex', 'claude']);
  fireEvent.change(ask, { target: { value: 'claude' } });
  await act(async () => { fireEvent.click(within(card(20)).getByRole('button', { name: 'Ask' })); });
  expect(posted, 'because the ask goes to the one reviewer picked').toEqual([{ kind: 'pr.review', args: { pr: '20', reviewer: 'claude' } }]);
});

test('AskForReview_OtherLogin_AskedWithoutItsAt', async () => {
  const { daemon, posted } = recordingDaemon();
  renderPulls([pull(20, {})], daemon);
  fireEvent.change(within(card(20)).getByLabelText('Ask for review from'), { target: { value: '__other__' } });
  expect((within(card(20)).getByRole('button', { name: 'Ask' }) as HTMLButtonElement).disabled, 'because there is no one to ask before a login is typed').toBe(true);
  fireEvent.change(within(card(20)).getByLabelText('GitHub login'), { target: { value: '@octo-cat' } });
  await act(async () => { fireEvent.click(within(card(20)).getByRole('button', { name: 'Ask' })); });
  expect(posted, 'because a person on the team can be asked too').toEqual([{ kind: 'pr.review', args: { pr: '20', reviewer: 'octo-cat' } }]);
});

test('DraftPull_NoAskForReview', () => {
  renderPulls([pull(20, { draft: true, state: 'draft' })]);
  expect(within(card(20)).queryByLabelText('Ask for review from'), 'because a draft is not ready for a review yet').toBeNull();
});

const forceMerge = (number: number): HTMLElement | null => within(card(number)).queryByRole('button', { name: 'Force merge' });

test('FailingPull_ForceMerge_PostsPrMergeWithForce', async () => {
  const { daemon, posted } = recordingDaemon();
  renderPulls([pull(22, { state: 'checks-failing', checks: { passed: 3, failed: 2, pending: 0 } })], daemon);
  await act(async () => { fireEvent.click(forceMerge(22)!); });
  expect(posted, 'because a force merge is the same merge with force, which the daemon turns into gh pr merge --admin').toEqual([{ kind: 'pr.merge', args: { pr: '22', force: 'true' } }]);
});

test('ForceMerge_NeverThePrimaryButton', () => {
  renderPulls([pull(22, { state: 'checks-failing', checks: { passed: 3, failed: 2, pending: 0 } })]);
  expect(forceMerge(22)?.classList.contains('primary'), 'because merging past the rules is never the action the card leads with').toBe(false);
});

test('ApprovedPullGithubBlocks_ForceMergeOffered', () => {
  renderPulls([pull(23, { state: 'approved', mergeState: 'BLOCKED' })]);
  expect(forceMerge(23), 'because GitHub refuses the plain merge, and only an admin merge goes past its rule').not.toBeNull();
});

test('ApprovedPullWaitingOnlyOnThreads_NoForceMerge', () => {
  renderPulls([pull(23, { state: 'approved', mergeState: 'CLEAN', unresolvedThreads: 1 })]);
  expect(forceMerge(23), 'because GitHub would merge it; the open thread is the flow\'s own wait, not a block to force past').toBeNull();
});

test('PullsNoAdminMergeCanHelp_NoForceMerge', () => {
  renderPulls([
    pull(30, { state: 'conflicts', mergeable: 'CONFLICTING' }), pull(31, { state: 'draft', draft: true }),
    pull(32, { state: 'checks-pending', checks: { passed: 3, failed: 0, pending: 1 } }), pull(33, { state: 'changes-requested', reviewDecision: 'CHANGES_REQUESTED' }),
  ]);
  for (const number of [30, 31, 32, 33]) expect(forceMerge(number), `because #${number} is a conflict, a draft, running checks or requested changes, which no admin merge should skip`).toBeNull();
});

test('ConflictingPull_ResolveConflicts_StartsTheCommentsPassOnItsItemAndPr', async () => {
  const { daemon, posted } = recordingDaemon();
  renderPulls([pull(30, { state: 'conflicts', mergeable: 'CONFLICTING', item: 'gh#30' })], daemon);
  await act(async () => { fireEvent.click(within(card(30)).getByRole('button', { name: 'Resolve conflicts' })); });
  expect(posted, 'because the comments job merges the base in first on a conflicting PR, run now on the jobs host for this one item, named by the PR the item may not have recorded').toEqual([{ kind: 'job.start', args: { job: 'comments', host: 'claude', item: 'gh#30', pr: '30' } }]);
});

test('ConflictingPull_PassRunning_CardSaysSo', async () => {
  const { daemon } = recordingDaemon();
  renderPulls([pull(30, { state: 'conflicts', mergeable: 'CONFLICTING', item: 'gh#30' })], daemon);
  await act(async () => { fireEvent.click(within(card(30)).getByRole('button', { name: 'Resolve conflicts' })); });
  expect(card(30).textContent, 'because the owner sees the conflict is being handled while the pass runs').toMatch(/A comments pass is running on gh#30: it merges main in first\./);
});

test('ConflictingPullWithNoItem_NoResolveConflicts', () => {
  renderPulls([pull(30, { state: 'conflicts', mergeable: 'CONFLICTING', item: null })]);
  expect(within(card(30)).queryByRole('button', { name: 'Resolve conflicts' }), 'because the comments pass is run for an item, and this PR has none').toBeNull();
});
