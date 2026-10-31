import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { CommandResult, CommandRunner } from '../src/collectors/exec.ts';
import { countChecks, parsePullList, parseThreadCounts, readPulls, threadsQuery } from '../src/collectors/pulls.ts';
import { FIXTURE_ROOT, PULL_LIST_JSON, REVIEW_THREADS_JSON, fakeRunner } from './fakeRunner.ts';

const REPO = 'example/fixture';
const FIXTURE_NUMBERS = [560, 20, 21, 22, 23];
const MAXIMUM_PULLS = 100;
const NOT_STARTED = '0001-01-01T00:00:00Z';

const result = (code: number | null, stdout: string, stderr: string, timedOut: boolean): CommandResult => ({ code, stdout, stderr, timedOut });
const listThen = (threads: CommandResult): CommandRunner => async (request) => (request.args[0] === 'pr' ? result(0, PULL_LIST_JSON, '', false) : threads);
const always = (answer: CommandResult): CommandRunner => async () => answer;
const byNumber = (pullNumber: number) => parsePullList(PULL_LIST_JSON).find((pull) => pull.number === pullNumber);

test('ListedPull_PendingReviewRequests_Counted', () => {
  const [pull] = parsePullList(JSON.stringify([{ number: 7, reviewRequests: [{ login: 'someone' }, { __typename: 'Bot', login: 'copilot-pull-request-reviewer' }] }]));
  assert.equal(pull?.reviewsRequested, 2, 'because each reviewer still requested is a review not given yet');
});

test('ListedPull_NoReviewRequests_Zero', () => {
  assert.equal(byNumber(560)?.reviewsRequested, 0, 'because gh lists no request field for a pull nobody was asked to review');
});

test('CapturedPull_BranchIsHeadRef', () => {
  assert.equal(byNumber(560)?.branch, 'flow/gh-310', 'because the head branch links the pull to a claim');
});

test('CapturedPull_AuthorIsLogin', () => {
  assert.equal(byNumber(560)?.author, 'FilipposKaragiannis', 'because the author is the login, not the gh author object');
});

test('CapturedPull_EmptyDecision_Null', () => {
  assert.equal(byNumber(560)?.reviewDecision, null, 'because gh prints an empty decision when the repo requires no review');
});

test('CapturedPull_FailedTwiceOnSameCheck_CountedOnce', () => {
  assert.deepEqual(byNumber(560)?.checks, { passed: 2, failed: 3, pending: 0 }, 'because eight rollup entries are five checks: three failed, two skipped');
});

test('PullList_ReRunCheck_LatestRunCounts', () => {
  assert.deepEqual(byNumber(20)?.checks, { passed: 4, failed: 0, pending: 0 }, 'because the domain tests passed on the later job, which replaces the failed one');
});

test('PullList_ForkPull_CrossRepository', () => {
  assert.equal(byNumber(23)?.crossRepository, true, 'because its head lives in another repository');
});

test('PullList_ChangesRequestedReview_Counted', () => {
  assert.equal(byNumber(21)?.changesRequested, 1, 'because one reviewer asked for changes');
});

test('Checks_InProgressRun_Pending', () => {
  assert.deepEqual(countChecks([{ __typename: 'CheckRun', name: 'build', status: 'IN_PROGRESS', conclusion: '' }]), { passed: 0, failed: 0, pending: 1 }, 'because a running check is not done');
});

test('Checks_PendingStatusContext_Pending', () => {
  assert.deepEqual(countChecks([{ __typename: 'StatusContext', context: 'ci/legacy', state: 'PENDING' }]), { passed: 0, failed: 0, pending: 1 }, 'because a commit status can still report');
});

test('Checks_ErroredStatusContext_Failed', () => {
  assert.deepEqual(countChecks([{ __typename: 'StatusContext', context: 'ci/lint', state: 'ERROR' }]), { passed: 0, failed: 1, pending: 0 }, 'because an errored status is red');
});

test('Checks_StaleConclusion_Failed', () => {
  assert.deepEqual(countChecks([{ __typename: 'CheckRun', name: 'build', status: 'COMPLETED', conclusion: 'STALE' }]), { passed: 0, failed: 1, pending: 0 }, 'because a stale run never turns green on its own');
});

test('Checks_CompletedWithoutConclusion_Failed', () => {
  assert.deepEqual(countChecks([{ __typename: 'CheckRun', name: 'build', status: 'COMPLETED', conclusion: null }]), { passed: 0, failed: 1, pending: 0 }, 'because a finished run with no verdict would otherwise be pending forever');
});

test('Checks_NeutralAndSkipped_Passed', () => {
  const counts = countChecks([
    { __typename: 'CheckRun', name: 'lint', status: 'COMPLETED', conclusion: 'NEUTRAL' },
    { __typename: 'CheckRun', name: 'sweep', status: 'COMPLETED', conclusion: 'SKIPPED' },
  ]);
  assert.deepEqual(counts, { passed: 2, failed: 0, pending: 0 }, 'because neither blocks a merge');
});

test('Checks_QueuedReRunWithZeroStart_WinsOverFailure', () => {
  const counts = countChecks([
    { __typename: 'CheckRun', workflowName: 'Domain', name: 'tests', status: 'COMPLETED', conclusion: 'FAILURE', startedAt: '2026-10-24T10:00:00Z' },
    { __typename: 'CheckRun', workflowName: 'Domain', name: 'tests', status: 'QUEUED', conclusion: '', startedAt: NOT_STARTED },
  ]);
  assert.deepEqual(counts, { passed: 0, failed: 0, pending: 1 }, 'because gh prints the zero time for a queued re-run, which is the latest run');
});

test('Checks_SameStartTime_UnfinishedWins', () => {
  const counts = countChecks([
    { __typename: 'CheckRun', workflowName: 'Domain', name: 'tests', status: 'COMPLETED', conclusion: 'FAILURE', startedAt: '2026-10-24T10:00:00Z' },
    { __typename: 'CheckRun', workflowName: 'Domain', name: 'tests', status: 'IN_PROGRESS', conclusion: '', startedAt: '2026-10-24T10:00:00Z' },
  ]);
  assert.deepEqual(counts, { passed: 0, failed: 0, pending: 1 }, 'because on a tie the run still going is the newer one');
});

test('ThreadCounts_OnlyUnresolvedCounted', () => {
  const counts = parseThreadCounts(REVIEW_THREADS_JSON, FIXTURE_NUMBERS);
  assert.deepEqual([...counts.values()], [1, 0, 2, 0, 0], 'because resolved threads need nothing more from anyone');
});

test('ThreadsQuery_OneAliasPerPull', () => {
  const numbers = Array.from({ length: MAXIMUM_PULLS }, (_unused, index) => index + 1);
  assert.equal(threadsQuery(numbers).match(/pullRequest\(number: /g)?.length, MAXIMUM_PULLS, 'because one query carries every pull gh pr list can return');
});

test('ReadPulls_Fixture_ThreadsJoinedByNumber', async () => {
  const { pulls } = await readPulls(FIXTURE_ROOT, REPO, fakeRunner);
  assert.deepEqual(pulls.map((pull) => [pull.number, pull.unresolvedThreads]), [[560, 1], [20, 0], [21, 2], [22, 0], [23, 0]], 'because each pull gets the unresolved count of its own alias');
});

test('ReadPulls_ListFails_ErrorCarriesStderr', async () => {
  await assert.rejects(readPulls(FIXTURE_ROOT, REPO, always(result(1, '', 'HTTP 401: Bad credentials\n', false))), /gh pr list failed: HTTP 401: Bad credentials/, 'because the freshness error must say why GitHub refused');
});

test('ReadPulls_ListFailsSilently_ErrorCarriesExitCode', async () => {
  await assert.rejects(readPulls(FIXTURE_ROOT, REPO, always(result(4, '', '', false))), /gh pr list failed: exit code 4/, 'because an empty stderr still has an exit code to show');
});

test('ReadPulls_ListTimesOut_SaysTimedOut', async () => {
  await assert.rejects(readPulls(FIXTURE_ROOT, REPO, always(result(null, '', '', true))), /^Error: gh pr list timed out after 60s$/, 'because a killed gh has no exit code to show');
});

test('ReadPulls_GraphqlFails_ErrorCarriesStderr', async () => {
  await assert.rejects(readPulls(FIXTURE_ROOT, REPO, listThen(result(1, '', 'gh: Something went wrong', false))), /review threads\) failed: gh: Something went wrong/, 'because a half-read pull list must not pass as fresh');
});

test('ReadPulls_GraphqlTimesOut_SaysTimedOut', async () => {
  await assert.rejects(readPulls(FIXTURE_ROOT, REPO, listThen(result(null, '', '', true))), /review threads\) timed out after 60s/, 'because the threads query has the same timeout');
});

test('ReadPulls_NoOpenPulls_EmptyWithoutGraphql', async () => {
  const runner: CommandRunner = async (request) => (request.args[0] === 'pr' ? result(0, '[]', '', false) : result(1, '', 'an empty threads query is invalid', false));
  assert.deepEqual(await readPulls(FIXTURE_ROOT, REPO, runner), { pulls: [] }, 'because a repo with no open pulls has nothing to show and no threads to ask about');
});
