import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseBoard } from '../src/collectors/board.ts';
import { readFlowHome } from '../src/collectors/flowHome.ts';
import { readGit } from '../src/collectors/git.ts';
import { parseJobStatus } from '../src/collectors/jobs.ts';
import { readProcesses } from '../src/collectors/processes.ts';
import type { PullFact } from '../src/collectors/pulls.ts';
import { readPulls } from '../src/collectors/pulls.ts';
import { pullState, reconcile } from '../src/reconcile.ts';
import type { ReconcileInput } from '../src/reconcile.ts';
import type { Freshness, Snapshot } from '../src/snapshot.ts';
import { BOARD_JSON, FIXTURE_ROOT, JOBS_JSON, fakeRunner } from './fakeRunner.ts';

const NOW = new Date('2026-10-24T18:16:04Z');
const fresh: Freshness = { at: NOW.toISOString(), ageSeconds: 0, ok: true, error: null };

async function input(): Promise<ReconcileInput> {
  return {
    now: NOW,
    project: { id: 'project', name: 'project', root: FIXTURE_ROOT },
    flow: await readFlowHome(FIXTURE_ROOT, fakeRunner),
    git: await readGit(FIXTURE_ROOT, 'main', fakeRunner),
    processes: await readProcesses(fakeRunner),
    jobs: { jobs: parseJobStatus(JOBS_JSON) },
    board: parseBoard(BOARD_JSON),
    pulls: await readPulls(FIXTURE_ROOT, 'example/fixture', fakeRunner),
    sources: { files: fresh, git: fresh, processes: fresh, jobs: fresh, board: fresh, pulls: fresh },
  };
}

async function snapshot(): Promise<Snapshot> { return reconcile(await input()); }

const worktree = (picture: Snapshot, name: string) => picture.worktrees.find((entry) => entry.name === name);

test('WorktreeWithAgentProcess_IsRunning', async () => {
  const running = worktree(await snapshot(), 'project-wt-3');
  assert.equal(running?.state, 'running', 'because a claude process has its cwd in the worktree');
  assert.deepEqual(running?.agentPids, [100], 'because that process is the agent');
  assert.ok(running?.flags.includes('dirty'), 'because git status lists two files');
});

test('WorktreeWithGateRecord_NeedsYou', async () => {
  const gated = worktree(await snapshot(), 'project-wt-2');
  assert.equal(gated?.state, 'needs-you', 'because its item has a gate record and no agent process');
  assert.ok(gated?.flags.includes('session'), 'because an interactive claude sits in a folder under the worktree');
  assert.deepEqual(gated?.sessionPids, [104], 'because the card shows who else is in there');
  assert.equal(gated?.gate, 'ambiguity', 'because the gate kind is shown on the card');
});

test('ClaimedWorktreeFarBehindBase_IsStale', async () => {
  const stale = worktree(await snapshot(), 'project-wt-4');
  assert.equal(stale?.state, 'stale', 'because 35 commits behind main crosses the health job threshold');
  assert.ok(stale?.flags.includes('stale-branch'), 'because the reason is the branch, not idleness alone');
  assert.ok(stale?.flags.includes('idle'), 'because it was claimed six days ago with no run, agent or gate');
});

test('MainAndSideWorktrees_AreOutsideThePool', async () => {
  const picture = await snapshot();
  assert.equal(worktree(picture, 'project')?.role, 'main', 'because the root is the flow home');
  assert.equal(worktree(picture, 'project-side')?.state, 'outside', 'because git lists it but the pool does not');
});

test('Counts_FollowPoolStates', async () => {
  const { counts } = await snapshot();
  assert.equal(counts.agents, 1, 'because a session is not an agent');
  assert.deepEqual([counts.needsYou, counts.running, counts.stale, counts.free], [1, 1, 1, 0], 'because the pool holds one of each and nothing free');
});

test('Gate_AgeOverdueWorktreeAndQuestions', async () => {
  const [gate] = (await snapshot()).gates;
  assert.equal(gate?.worktree, 'project-wt-2', 'because the claim links the gate to its worktree');
  assert.equal(gate?.overdue, true, 'because it was raised more than 24 hours before now');
  assert.equal(gate?.questions.length, 2, 'because the message numbers two questions');
});

test('Items_StateFromEngagementThenBoard', async () => {
  const states = Object.fromEntries((await snapshot()).items.map((item) => [item.id, item.state]));
  assert.equal(states['gh#7'], 'needs-you', 'because its worktree waits at a gate');
  assert.equal(states['gh#9'], 'running', 'because its worktree has an agent');
  assert.equal(states['gh#5'], 'stale', 'because its worktree is stale, even though the board never listed the item');
  assert.equal(states['gh#12'], 'ready', 'because it is open, sized, prioritised and unblocked');
  assert.equal(states['gh#13'], 'blocked', 'because gh#12 blocks it');
  assert.equal(states['gh#2'], 'done', 'because it is closed');
});

test('Items_EngagedFirstThenRank', async () => {
  const ids = (await snapshot()).items.map((item) => item.id);
  assert.deepEqual(ids.slice(0, 3), ['gh#7', 'gh#9', 'gh#5'], 'because what needs you comes before what runs, then stale, before the backlog');
});

test('Items_BodyDropped', async () => {
  const seven = parseBoard(BOARD_JSON).items[0] as unknown as Record<string, unknown>;
  assert.equal('body' in seven, false, 'because the snapshot must stay small');
});

test('Disagreements_DeadRunGateLabelsAndMergeless', async () => {
  const messages = (await snapshot()).disagreements.map((entry) => entry.sources.join(' vs '));
  assert.ok(messages.includes('gate record vs issue labels'), 'because gh#7 has a gate record and the issue says none');
  assert.ok(messages.includes('issue state vs pull request'), 'because gh#20 is done, its PR is ready to merge and no merge gate asks for it');
  assert.equal(messages.includes('run record vs process list'), false, 'because gh#9 has both a record and a process');
});

test('RunWithoutProcess_IsDeadAndFlagged', async () => {
  const facts = await input();
  facts.processes = { agents: [] };
  const picture = reconcile(facts);
  assert.equal(picture.runs[0]?.alive, false, 'because no process sits in the worktree');
  assert.ok(worktree(picture, 'project-wt-3')?.flags.includes('dead-run'), 'because the card must say the run is a ghost');
  assert.equal(worktree(picture, 'project-wt-3')?.state, 'claimed', 'because a dead run is not running');
  assert.ok(picture.attention.some((row) => row.kind === 'dead-run'), 'because a ghost run needs a human');
});

test('Jobs_StateFromRows', async () => {
  const states = Object.fromEntries((await snapshot()).jobs.map((job) => [job.name, job.state]));
  assert.deepEqual(states, { next: 'due', health: 'running', retro: 'paused' }, 'because next is due, health has a running entry and retro is paused');
});

test('Attention_OldestFirstWithFailedJob', async () => {
  const rows = (await snapshot()).attention;
  assert.equal(rows[0]?.kind, 'stale', 'because the six-day-old claim is the oldest thing waiting');
  assert.equal(rows[1]?.kind, 'gate', 'because the gate is two days old');
  assert.ok(rows.some((row) => row.kind === 'job-failed' && row.id === 'health'), 'because the health job exited 1 last time');
});

test('NoBoardYet_EngagedItemsStillListed', async () => {
  const facts = await input();
  facts.board = null;
  const ids = reconcile(facts).items.map((item) => item.id).sort();
  assert.deepEqual(ids, ['gh#5', 'gh#7', 'gh#9'], 'because claims and gates alone name the engaged items');
});

const READY: PullFact = {
  number: 30, title: 'Thirty', url: 'https://example/pull/30', branch: 'flow/gh-30', base: 'main', head: '3030303', author: 'someone',
  draft: false, mergeable: 'MERGEABLE', mergeState: 'CLEAN', reviewDecision: 'APPROVED', approvals: 1, changesRequested: 0,
  requestedReviewers: [], checks: { passed: 3, failed: 0, pending: 0 }, unresolvedThreads: 0,
  createdAt: '2026-10-23T18:16:04Z', updatedAt: '2026-10-24T17:16:04Z',
};
const ready = (change: Partial<PullFact>): PullFact => ({ ...READY, ...change });

test('PullState_ApprovedGreenCleanMergeable_Mergeable', () => {
  assert.equal(pullState(READY), 'mergeable', 'because nothing stands between the pull and a merge');
});

test('PullState_DraftWithEverythingWrong_Draft', () => {
  assert.equal(pullState(ready({ draft: true, mergeable: 'CONFLICTING', checks: { passed: 0, failed: 2, pending: 0 } })), 'draft', 'because a draft is not asking for anything yet');
});

test('PullState_ConflictsAndFailingChecks_Conflicts', () => {
  assert.equal(pullState(ready({ mergeable: 'CONFLICTING', checks: { passed: 0, failed: 2, pending: 0 } })), 'conflicts', 'because checks on a conflicting head say little until the base is merged in');
});

test('PullState_FailingChecksAndChangesRequested_ChecksFailing', () => {
  assert.equal(pullState(ready({ reviewDecision: 'CHANGES_REQUESTED', checks: { passed: 1, failed: 1, pending: 0 } })), 'checks-failing', 'because a red build is fixed before the review is answered');
});

test('PullState_ChangesRequestedWithPendingChecks_ChangesRequested', () => {
  assert.equal(pullState(ready({ reviewDecision: 'CHANGES_REQUESTED', checks: { passed: 1, failed: 0, pending: 1 } })), 'changes-requested', 'because a reviewer asked for changes whatever the running check says');
});

test('PullState_NoDecisionButRequestingReview_ChangesRequested', () => {
  assert.equal(pullState(ready({ reviewDecision: null, approvals: 1, changesRequested: 1 })), 'changes-requested', 'because without a required review the latest reviews decide');
});

test('PullState_PendingChecks_ChecksPending', () => {
  assert.equal(pullState(ready({ checks: { passed: 2, failed: 0, pending: 1 } })), 'checks-pending', 'because a check is still running');
});

test('PullState_GreenWithoutApproval_ReviewPending', () => {
  assert.equal(pullState(ready({ reviewDecision: 'REVIEW_REQUIRED', approvals: 1 })), 'review-pending', 'because the repo still requires another approval');
});

test('PullState_NoDecisionNoReviews_ReviewPending', () => {
  assert.equal(pullState(ready({ reviewDecision: null, approvals: 0 })), 'review-pending', 'because nobody approved yet');
});

test('PullState_ApprovedWithUnresolvedThread_Approved', () => {
  assert.equal(pullState(ready({ unresolvedThreads: 1 })), 'approved', 'because an open thread still waits for an answer');
});

test('PullState_ApprovedButMergeabilityUnknown_Approved', () => {
  assert.equal(pullState(ready({ mergeable: 'UNKNOWN' })), 'approved', 'because GitHub has not yet said the pull merges cleanly');
});

test('Pulls_FixtureStates', async () => {
  const states = Object.fromEntries((await snapshot()).pulls.map((pull) => [pull.number, pull.state]));
  assert.deepEqual(states, { 560: 'checks-failing', 20: 'mergeable', 21: 'changes-requested', 22: 'draft' }, 'because each fixture pull stops at a different step of the precedence');
});

test('Pulls_ItemPrUrl_LinksItem', async () => {
  const twenty = (await snapshot()).pulls.find((pull) => pull.number === 20);
  assert.equal(twenty?.item, 'gh#20', 'because the issue state names the pull by URL');
});

test('Pulls_ItemPrNumber_LinksItemBeforeBranch', async () => {
  const facts = await input();
  facts.board = { items: (facts.board?.items ?? []).map((item) => (item.id === 'gh#12' ? { ...item, state: { ...item.state, pr: '#21' } } : item)) };
  const twentyOne = reconcile(facts).pulls.find((pull) => pull.number === 21);
  assert.equal(twentyOne?.item, 'gh#12', 'because the item that names the pull wins over a branch that happens to match');
});

test('Pulls_ItemPrUrlOfAnotherRepo_NoLink', async () => {
  const facts = await input();
  facts.board = { items: (facts.board?.items ?? []).map((item) => (item.id === 'gh#20' ? { ...item, state: { ...item.state, pr: 'https://elsewhere/pull/20' } } : item)) };
  const twenty = reconcile(facts).pulls.find((pull) => pull.number === 20);
  assert.equal(twenty?.item, null, 'because the same number in another repository is another pull');
});

test('Pulls_ClaimBranch_LinksItemAndWorktree', async () => {
  const twentyOne = (await snapshot()).pulls.find((pull) => pull.number === 21);
  assert.deepEqual([twentyOne?.item, twentyOne?.worktree], ['gh#9', 'project-wt-3'], 'because the pull head is the branch claimed in project-wt-3');
});

test('Pulls_AgesFromCreatedAndUpdated', async () => {
  const twenty = (await snapshot()).pulls.find((pull) => pull.number === 20);
  assert.deepEqual([twenty?.ageSeconds, twenty?.idleSeconds], [375364, 22564], 'because it was opened at 10:00 four days before now and last touched at noon today');
});

test('Attention_PullRows_FailingChangesRequestedMergeable', async () => {
  const rows = (await snapshot()).attention.filter((row) => row.kind.startsWith('pr-'));
  assert.deepEqual(rows.map((row) => [row.kind, row.id]).sort(), [['pr-changes-requested', 'gh#9'], ['pr-failing', '#560'], ['pr-mergeable', 'gh#20']], 'because a draft asks for nothing and each other state names its item, or the pull when no item claims it');
});

test('Attention_MergeablePull_ReadyToMerge', async () => {
  const row = (await snapshot()).attention.find((entry) => entry.kind === 'pr-mergeable');
  assert.equal(row?.title, '#20 ready to merge', 'because the row tells you what to do');
});

test('Disagreement_DonePullMergeableWithMergeGate_None', async () => {
  const facts = await input();
  facts.board = { items: (facts.board?.items ?? []).map((item) => (item.id === 'gh#20' ? { ...item, state: { ...item.state, gate: 'merge' } } : item)) };
  const sources = reconcile(facts).disagreements.map((entry) => entry.sources.join(' vs '));
  assert.equal(sources.includes('issue state vs pull request'), false, 'because the merge gate already asks you to merge it');
});

test('Disagreement_DonePullNotMergeable_None', async () => {
  const facts = await input();
  facts.pulls = { pulls: (facts.pulls?.pulls ?? []).map((pull) => (pull.number === 20 ? { ...pull, unresolvedThreads: 1 } : pull)) };
  const sources = reconcile(facts).disagreements.map((entry) => entry.sources.join(' vs '));
  assert.equal(sources.includes('issue state vs pull request'), false, 'because a pull with an open thread is not ready, so nothing is missing a merge gate');
});

test('Counts_PullStates', async () => {
  const { counts } = await snapshot();
  assert.deepEqual([counts.prsMergeable, counts.prsFailing, counts.prsChangesRequested], [1, 1, 1], 'because the fixture holds one ready, one failing and one with changes requested');
});
