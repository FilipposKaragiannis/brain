import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import type { FlowEvent, Job, MergedPull, PullRequest, Snapshot, Worktree } from '../../daemon/src/snapshot.ts';
import { Pulls } from '../src/screens/Pulls.tsx';
import { actionRecord, FakeDaemon, HTTP_ACCEPTED, poolWorktree, snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

afterEach(cleanup);

function pull(number: number, change: Partial<PullRequest>): PullRequest {
  return {
    number, title: `Pull ${number}`, url: `https://github.com/owner/project/pull/${number}`, branch: `flow/gh-${number}`, base: 'main', author: 'owner',
    draft: false, state: 'mergeable', checks: { passed: 5, failed: 0, pending: 0 }, checkRuns: [], head: null, autoMerge: null, reviewDecision: 'APPROVED', unresolvedThreads: 0, mergeable: 'MERGEABLE', mergeState: 'CLEAN',
    item: null, worktree: null, createdAt: TAKEN_AT, updatedAt: TAKEN_AT, ageSeconds: 3600, idleSeconds: 600, review: null, quiz: null, ...change,
  };
}

function renderPulls(pulls: PullRequest[], daemon = new FakeDaemon(), change: Partial<Snapshot> = {}): void {
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><Pulls snapshot={{ ...snapshotAt(TAKEN_AT, 0), pulls, ...change }} /></Wrapper>);
}

const card = (number: number): HTMLElement => screen.getByRole('region', { name: `PR #${number}` });
const mergeNow = (number: number): HTMLButtonElement => within(card(number)).getByRole('button', { name: 'Merge now' }) as HTMLButtonElement;

test('InReviewPull_SaysWhoItWaitsOnAndOffersNoMerge', () => {
  renderPulls([pull(20, { state: 'in-review', review: { state: 'in-review', waiting: ['codex'], cannot: [], at: TAKEN_AT } })]);
  expect(card(20).textContent, 'because the pull waits on a reviewer asked by a mention').toMatch(/in review/);
  expect(card(20).textContent, 'because the owner sees who it waits on').toMatch(/waiting on codex/);
  expect(mergeNow(20).disabled, 'because a pull still in review is not the owner\'s to merge yet').toBe(true);
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
  expect(mergeNow(21).disabled, 'because a ready pull is merged from its card').toBe(false);
  expect(card(21).textContent, 'because the health strip says the checks are green').toMatch(/all 5 passed/);
});

test('FailingPull_NoMergeAndTheReason', () => {
  renderPulls([pull(22, { state: 'checks-failing', checks: { passed: 3, failed: 2, pending: 0 } })]);
  expect(mergeNow(22).disabled, 'because failing checks must not be merged from a button').toBe(true);
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
    const action = body as { kind: 'pr.review' | 'pr.merge' | 'pr.auto-merge' | 'job.start' | 'job.run'; args: Record<string, string> };
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

const COMMENTS_JOB: Job = { name: 'comments', job: 'comments', host: 'claude', configured: true, state: 'scheduled', schedule: 'every 10m', args: '', installed: true, loaded: true, paused: false, running: [], last: null, recent: [], workers: [], next: '18:30', runsThisWeek: 0, failedThisWeek: 0 };
const event = (at: string, item: string, kind: string, message: string): FlowEvent => ({ at, item, kind, message });
const MERGED: MergedPull = { number: 19, title: 'Nineteen', url: 'https://github.com/owner/project/pull/19', branch: 'flow/gh-9', item: 'gh#9', createdAt: '2026-10-20T09:00:00Z', mergedAt: '2026-10-24T17:48:00Z' };

test('Card_HeadNamesBranchAndLinksToGitHub', () => {
  renderPulls([pull(21, {})]);
  expect(card(21).textContent, 'because the head says which branch merges into which').toMatch(/flow\/gh-21 → main/);
  expect(within(card(21)).getByRole('link', { name: 'Open on GitHub' }).getAttribute('href'), 'because the PR itself is one click away').toBe('https://github.com/owner/project/pull/21');
});

test('Card_SixHealthCells_StateFirstQuizLast', () => {
  renderPulls([pull(21, {})]);
  const labels = [...card(21).querySelectorAll('.pull-cell-label')].map((label) => label.textContent);
  expect(labels, 'because the strip reads as the prototype draws it').toEqual(['State', 'Checks', 'Conflicts', 'Review', 'Threads', 'Quiz']);
});

test('Checks_FailedNamedOnTheHead_PassedFolded', () => {
  renderPulls([pull(22, {
    state: 'checks-failing', head: 'e85e542c99', checks: { passed: 2, failed: 1, pending: 0 },
    checkRuns: [
      { name: 'Domain tests', outcome: 'failed', at: '2026-10-24T18:15:00Z', url: 'https://github.com/owner/project/actions/runs/1' },
      { name: 'Lint', outcome: 'passed', at: null, url: null }, { name: 'Build', outcome: 'passed', at: null, url: null },
    ],
  })]);
  const checks = within(card(22)).getByRole('list', { name: 'Checks' });
  expect(card(22).textContent, 'because the checks are those of one commit').toMatch(/Checks on e85e542c/);
  expect(within(checks).getByRole('link', { name: 'Domain tests' }).getAttribute('href'), 'because a failed check links to its run').toBe('https://github.com/owner/project/actions/runs/1');
  expect(checks.textContent, 'because the passed checks need nothing and fold into one row').toMatch(/2 other checks/);
});

test('Timeline_TodaysEventsOnTheItem_NewestFirst', () => {
  renderPulls([pull(22, { item: 'gh#22', createdAt: '2026-10-20T09:00:00Z' })], new FakeDaemon(), { events: [
    event('2026-10-24T18:15:00Z', 'gh#22', 'review', 'codex: no major issues'),
    event('2026-10-24T18:01:00Z', 'gh#22', 'job-start', 'comments job started'),
    event('2026-10-24T17:00:00Z', 'gh#9', 'review', 'another item'),
    event('2026-10-21T10:00:00Z', 'gh#22', 'review', 'an older day'),
  ] });
  const today = within(card(22)).getByRole('list', { name: 'Today' });
  expect([...today.querySelectorAll('.pull-timeline-text')].map((entry) => entry.textContent), 'because the card tells today\'s story of its own item, newest first').toEqual(['review: codex: no major issues', 'job-start: comments job started']);
});

test('MergeWhenGreen_PostsAutoMerge', async () => {
  const { daemon, posted } = recordingDaemon();
  renderPulls([pull(22, { state: 'checks-pending', checks: { passed: 3, failed: 0, pending: 1 } })], daemon);
  await act(async () => { fireEvent.click(within(card(22)).getByRole('button', { name: 'Merge when green' })); });
  expect(posted, 'because GitHub\'s auto-merge merges it once the checks pass').toEqual([{ kind: 'pr.auto-merge', args: { pr: '22' } }]);
});

test('ArmedPull_SaysSoAndOffersDisarm', async () => {
  const { daemon, posted } = recordingDaemon();
  renderPulls([pull(22, { state: 'checks-pending', autoMerge: { method: 'SQUASH', at: TAKEN_AT } })], daemon);
  expect(card(22).textContent, 'because the owner sees the merge is armed and how it merges').toMatch(/Armed · squash-merges when its checks and reviews pass/);
  await act(async () => { fireEvent.click(within(card(22)).getByRole('button', { name: 'Disarm' })); });
  expect(posted, 'because Disarm takes the armed merge back').toEqual([{ kind: 'pr.auto-merge', args: { pr: '22', off: 'true' } }]);
});

test('PullsNoWaitCanMerge_NoMergeWhenGreen', () => {
  renderPulls([pull(30, { state: 'conflicts', mergeable: 'CONFLICTING' }), pull(31, { state: 'draft', draft: true }), pull(32, {})]);
  for (const number of [30, 31, 32]) expect(within(card(number)).queryByRole('button', { name: 'Merge when green' }), `because #${number} is a conflict, a draft or ready now`).toBeNull();
});

test('FailingPull_FixChecks_StartsTheCommentsPassOnItsItemAndPr', async () => {
  const { daemon, posted } = recordingDaemon();
  renderPulls([pull(22, { state: 'checks-failing', checks: { passed: 3, failed: 2, pending: 0 }, item: 'gh#22' })], daemon);
  await act(async () => { fireEvent.click(within(card(22)).getByRole('button', { name: 'Ask the agent to fix the checks' })); });
  expect(posted, 'because the comments pass reads the failed runs and fixes the change').toEqual([{ kind: 'job.start', args: { job: 'comments', host: 'claude', item: 'gh#22', pr: '22' } }]);
});

test('MergedToday_ListedWithItsItemAndHowLongItWasOpen', () => {
  renderPulls([], new FakeDaemon(), { mergedToday: [MERGED] });
  const merged = screen.getByRole('list', { name: 'Merged today' });
  expect(within(merged).getByRole('link', { name: '#19' }).getAttribute('href'), 'because each merged pull links to itself').toBe(MERGED.url);
  expect(merged.textContent, 'because each merged pull names its item and title').toMatch(/gh#9 Nineteen/);
  expect(merged.textContent, 'because the open time runs from opening to merge').toMatch(/open 4d 8h/);
  expect(screen.getByLabelText('Summary').textContent, 'because the head line counts them').toMatch(/1 merged today/);
});

test('RunCommentsJobNow_InstalledSchedule_HandedToLaunchd', async () => {
  const { daemon, posted } = recordingDaemon();
  renderPulls([pull(21, {})], daemon, { jobs: [COMMENTS_JOB] });
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Run comments job now' })); });
  expect(posted, 'because the installed schedule runs now as it would on its next tick').toEqual([{ kind: 'job.run', args: { job: 'comments' } }]);
});

test('NoCommentsJob_NoRunNowButton', () => {
  renderPulls([pull(21, {})]);
  expect(screen.queryByRole('button', { name: 'Run comments job now' }), 'because there is no comments job to run').toBeNull();
});

/** PR 24 of gh#24, claimed in wt-4, with these flags on wt-4. */
function renderPullInWorktreeFlagged(flags: Worktree['flags']): void {
  renderPulls([pull(24, { item: 'gh#24', worktree: 'wt-4' })], new FakeDaemon(), { worktrees: [{ ...poolWorktree('wt-4'), state: 'claimed', item: 'gh#24', flags }] });
}

test('PullWhoseWorktreeHoldsASession_SaysTheCommentsJobSkipsIt', () => {
  renderPullInWorktreeFlagged(['session', 'comments-skipped']);
  expect(card(24).textContent, 'because the owner learns why the comments on the PR stay unaddressed').toMatch(/The comments job skips this PR while a session works in wt-4/);
});

test('PullWhoseWorktreeIsNotSkipped_NoSkipLine', () => {
  renderPullInWorktreeFlagged([]);
  expect(card(24).textContent, 'because the comments job addresses a PR whose worktree nobody works in').not.toMatch(/The comments job skips/);
});
