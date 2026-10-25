import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { CommandRequest, CommandResult, CommandRunner } from '../src/collectors/exec.ts';
import { countChecks, parsePullList, parseThreadCounts, readPulls, threadsQuery } from '../src/collectors/pulls.ts';
import { FIXTURE_ROOT, PULL_LIST_JSON, REVIEW_THREADS_JSON, fakeRunner } from './fakeRunner.ts';

const REPO = 'example/fixture';
const FIXTURE_NUMBERS = [560, 20, 21, 22];
const MAXIMUM_PULLS = 100;

function recording(answer: (request: CommandRequest) => CommandResult): { runner: CommandRunner } {
  return { runner: async (request) => answer(request) };
}

test('PullList_CapturedShape_PlainFields', () => {
  const [captured] = parsePullList(PULL_LIST_JSON);
  assert.equal(captured?.number, 560, 'because the number names the pull');
  assert.equal(captured?.branch, 'flow/gh-310', 'because the head branch links the pull to a claim');
  assert.equal(captured?.author, 'FilipposKaragiannis', 'because the author is the login, not the gh author object');
  assert.equal(captured?.reviewDecision, null, 'because gh prints an empty decision when the repo requires no review');
  assert.equal(captured?.mergeable, 'MERGEABLE', 'because GitHub computed no conflicts');
});

test('PullList_ReRunCheck_LatestRunCounts', () => {
  const [captured] = parsePullList(PULL_LIST_JSON);
  assert.deepEqual(captured?.checks, { passed: 2, failed: 1, pending: 0 }, 'because the smoke tier passed on its re-run, the domain tests failed twice and count once, and a skipped check passes');
});

test('Checks_InProgressAndStatusContext_Pending', () => {
  const counts = countChecks([
    { __typename: 'CheckRun', name: 'build', status: 'IN_PROGRESS', conclusion: '' },
    { __typename: 'StatusContext', context: 'ci/legacy', state: 'PENDING' },
    { __typename: 'StatusContext', context: 'ci/lint', state: 'ERROR' },
  ]);
  assert.deepEqual(counts, { passed: 0, failed: 1, pending: 2 }, 'because a running check and a pending status are not done, and an errored status failed');
});

test('PullList_Reviews_ApprovalsAndRequestsCounted', () => {
  const byNumber = new Map(parsePullList(PULL_LIST_JSON).map((pull) => [pull.number, pull]));
  assert.equal(byNumber.get(20)?.approvals, 1, 'because one reviewer approved');
  assert.equal(byNumber.get(21)?.changesRequested, 1, 'because one reviewer asked for changes');
  assert.deepEqual(byNumber.get(21)?.requestedReviewers, ['codex'], 'because codex was asked and has not answered');
});

test('ThreadCounts_OnlyUnresolvedCounted', () => {
  const counts = parseThreadCounts(REVIEW_THREADS_JSON, FIXTURE_NUMBERS);
  assert.deepEqual([...counts.values()], [1, 0, 2, 0], 'because resolved threads need nothing more from anyone');
});

test('ThreadsQuery_OneAliasPerPull', () => {
  const numbers = Array.from({ length: MAXIMUM_PULLS }, (_unused, index) => index + 1);
  const query = threadsQuery(numbers);
  assert.equal(query.match(/pullRequest\(number: /g)?.length, MAXIMUM_PULLS, 'because one query carries every pull gh pr list can return');
});

test('ReadPulls_Fixture_ThreadsJoinedByNumber', async () => {
  const { pulls } = await readPulls(FIXTURE_ROOT, REPO, fakeRunner);
  assert.deepEqual(pulls.map((pull) => [pull.number, pull.unresolvedThreads]), [[560, 1], [20, 0], [21, 2], [22, 0]], 'because each pull gets the unresolved count of its own alias');
});

test('ReadPulls_ListFails_ErrorCarriesStderr', async () => {
  const { runner } = recording(() => ({ code: 1, stdout: '', stderr: 'HTTP 401: Bad credentials\n', timedOut: false }));
  await assert.rejects(readPulls(FIXTURE_ROOT, REPO, runner), /Bad credentials/, 'because the freshness error must say why GitHub refused');
});

test('ReadPulls_GraphqlFails_ErrorCarriesStderr', async () => {
  const { runner } = recording((request) => (request.args[0] === 'pr'
    ? { code: 0, stdout: PULL_LIST_JSON, stderr: '', timedOut: false }
    : { code: 1, stdout: '', stderr: 'gh: Something went wrong', timedOut: false }));
  await assert.rejects(readPulls(FIXTURE_ROOT, REPO, runner), /review threads.*Something went wrong/, 'because a half-read pull list must not pass as fresh');
});

test('ReadPulls_NoOpenPulls_EmptyWithoutGraphql', async () => {
  const { runner } = recording((request) => (request.args[0] === 'pr'
    ? { code: 0, stdout: '[]', stderr: '', timedOut: false }
    : { code: 1, stdout: '', stderr: 'an empty threads query is invalid', timedOut: false }));
  assert.deepEqual(await readPulls(FIXTURE_ROOT, REPO, runner), { pulls: [] }, 'because a repo with no open pulls has nothing to show and no threads to ask about');
});
