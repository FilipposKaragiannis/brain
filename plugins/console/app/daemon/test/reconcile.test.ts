import assert from 'node:assert/strict';
import { test } from 'node:test';
import type { BoardItem } from '../src/collectors/board.ts';
import { parseBoard } from '../src/collectors/board.ts';
import { readFlowHome } from '../src/collectors/flowHome.ts';
import { readGit } from '../src/collectors/git.ts';
import { parseJobStatus } from '../src/collectors/jobs.ts';
import { readProcesses } from '../src/collectors/processes.ts';
import type { PullFact } from '../src/collectors/pulls.ts';
import { readPulls } from '../src/collectors/pulls.ts';
import { pullState, reconcile } from '../src/reconcile.ts';
import type { ReconcileInput } from '../src/reconcile.ts';
import { DisagreementSettler } from '../src/settle.ts';
import type { ReadMarks } from '../src/settle.ts';
import type { Freshness, Snapshot } from '../src/snapshot.ts';
import { BOARD_JSON, FIXTURE_ROOT, JOBS_JSON, LOCAL_BOARD_JSON, fakeRunner } from './fakeRunner.ts';

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
  assert.deepEqual(running?.agents.map((agent) => agent.pid), [100], 'because that process is the agent');
  assert.ok(running?.flags.includes('dirty'), 'because git status lists two files');
});

test('WorktreeWithGateRecord_NeedsYou', async () => {
  const gated = worktree(await snapshot(), 'project-wt-2');
  assert.equal(gated?.state, 'needs-you', 'because its item has a gate record and no agent process');
  assert.ok(gated?.flags.includes('session'), 'because an interactive claude sits in a folder under the worktree');
  assert.deepEqual(gated?.sessions.map((session) => session.pid), [104], 'because the card shows who else is in there');
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

test('Gate_PluginQuestions_Shown', async () => {
  assert.equal((await snapshot()).gates[0]?.questions[1]?.recommended, 'no, the plugin said so', 'because the plugin parsed the message, so the card matches Slack');
});

test('Gate_EmptyPluginQuestions_DaemonParses', async () => {
  const facts = await input();
  facts.flow.gates[0]!.questions = [];
  assert.equal(reconcile(facts).gates[0]?.questions[1]?.recommended, 'no.', 'because the plugin gives no questions for some messages and the card still needs one');
});

test('Gate_NoPluginQuestions_DaemonParses', async () => {
  const facts = await input();
  facts.flow.gates[0]!.questions = null;
  assert.equal(reconcile(facts).gates[0]?.questions.length, 2, 'because an older plugin gives no parse and the daemon reads the message');
});

test('Gate_AgeOverdueWorktreeAndQuestions', async () => {
  const [gate] = (await snapshot()).gates;
  assert.equal(gate?.worktree, 'project-wt-2', 'because the claim links the gate to its worktree');
  assert.equal(gate?.overdue, true, 'because it was raised more than 24 hours before now');
  assert.equal(gate?.questions.length, 2, 'because the plugin lists two questions for the gate');
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

test('Items_NothingLeftToRun_NotReady', async () => {
  const facts = withBoardItems(await input(), [
    { id: 'gh#40', state: { step: 'done', gate: 'none', worktree: '', pr: '', last_event: '', profile: 'task-S', attempts: 0 } },
    { id: 'gh#41', state: { step: 'split', gate: 'none', worktree: '', pr: '', last_event: '', profile: 'task-M', attempts: 0 }, open_children: 2 },
    { id: 'gh#42', state: { step: 'split', gate: 'none', worktree: '', pr: '', last_event: '', profile: 'task-M', attempts: 0 }, open_children: 0 },
  ]);
  const states = Object.fromEntries(reconcile(facts).items.map((item) => [item.id, item.state]));
  assert.equal(states['gh#40'], 'needs-you', 'because every step ran and the owner merges or closes it; the next job never takes it');
  assert.equal(states['gh#41'], 'blocked', 'because a split item waits on its open children');
  assert.equal(states['gh#42'], 'needs-you', 'because a split item whose children are closed is the owner\'s to close');
});

test('Items_EngagedFirstThenRank', async () => {
  const ids = (await snapshot()).items.map((item) => item.id);
  assert.deepEqual(ids.slice(0, 4), ['gh#7', 'gh#20', 'gh#9', 'gh#5'], 'because what needs you (a gate, or every step ran with nobody to merge or close it) comes before what runs, then stale, before the backlog');
});

test('Items_BodyDropped', async () => {
  const seven = parseBoard(BOARD_JSON).items[0] as unknown as Record<string, unknown>;
  assert.equal('body' in seven, false, 'because the snapshot must stay small');
});

test('LocalBoard_ComputedFieldsFilledIn', () => {
  const byId = Object.fromEntries(parseBoard(LOCAL_BOARD_JSON).items.map((item) => [item.id, item]));
  assert.deepEqual(byId['local:task/3']?.open_blockers, ['local:task/1'], 'because its blocker is an open item on the board');
  assert.deepEqual(byId['local:task/4']?.open_blockers, [], 'because its blocker is closed, so the board does not list it');
  assert.deepEqual([byId['local:task/1']?.rank, byId['local:task/1']?.needs], [999, []], 'because the local adapter ranks nothing and lists no needs');
});

test('LocalBoard_ItemsGetStates', async () => {
  const facts = await input();
  facts.board = parseBoard(LOCAL_BOARD_JSON);
  const states = Object.fromEntries(reconcile(facts).items.map((item) => [item.id, item.state]));
  assert.deepEqual([states['local:task/1'], states['local:task/3'], states['local:task/4']], ['ready', 'blocked', 'ready'], 'because the daemon crashed on these items before, and only the open blocker holds one back');
});

test('Disagreements_DeadRunGateLabelsAndMergeless', async () => {
  const messages = (await snapshot()).disagreements.map((entry) => entry.sources.join(' vs '));
  assert.ok(messages.includes('gate record vs issue labels'), 'because gh#7 has a gate record and the issue says none');
  assert.ok(messages.includes('issue state vs pull request'), 'because gh#20 is done with an open PR and no merge gate');
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
  number: 30, title: 'Thirty', url: 'https://example/pull/30', branch: 'flow/gh-30', base: 'main', author: 'someone',
  draft: false, crossRepository: false, mergeable: 'MERGEABLE', mergeState: 'CLEAN', reviewDecision: 'APPROVED', changesRequested: 0,
  checks: { passed: 3, failed: 0, pending: 0 }, unresolvedThreads: 0,
  createdAt: '2026-10-23T18:16:04Z', updatedAt: '2026-10-24T17:16:04Z',
};
const ready = (change: Partial<PullFact>): PullFact => ({ ...READY, ...change });
const pullNumbered = (picture: Snapshot, pullNumber: number) => picture.pulls.find((pull) => pull.number === pullNumber);
const withBoardItem = (facts: ReconcileInput, id: string, change: Partial<BoardItem['state']>): ReconcileInput => ({
  ...facts, board: { items: (facts.board?.items ?? []).map((item) => (item.id === id ? { ...item, state: { ...item.state, ...change } } : item)), bodies: facts.board?.bodies ?? {} },
});
const mergeDisagreements = (picture: Snapshot) => picture.disagreements.filter((entry) => entry.sources.join(' vs ') === 'issue state vs pull request');

test('PullState_ApprovedGreenCleanMergeable_Mergeable', () => {
  assert.equal(pullState(READY), 'mergeable', 'because nothing stands between the pull and a merge');
});

test('PullState_NoReviewRequiredGreenClean_Mergeable', () => {
  assert.equal(pullState(ready({ reviewDecision: null })), 'mergeable', 'because a repository that requires no review needs no approval');
});

test('PullState_NoReviewRequiredUnstable_Mergeable', () => {
  assert.equal(pullState(ready({ reviewDecision: null, mergeState: 'UNSTABLE' })), 'mergeable', 'because UNSTABLE only means a check no rule requires is red');
});

test('PullState_DraftWithEverythingWrong_Draft', () => {
  assert.equal(pullState(ready({ draft: true, mergeable: 'CONFLICTING', checks: { passed: 0, failed: 2, pending: 0 } })), 'draft', 'because a draft is not asking for anything yet');
});

test('PullState_ConflictingWithFailingChecks_Conflicts', () => {
  assert.equal(pullState(ready({ mergeable: 'CONFLICTING', checks: { passed: 0, failed: 2, pending: 0 } })), 'conflicts', 'because checks on a conflicting head say little until the base is merged in');
});

test('PullState_MergeStateDirty_Conflicts', () => {
  assert.equal(pullState(ready({ mergeable: 'UNKNOWN', mergeState: 'DIRTY' })), 'conflicts', 'because DIRTY is GitHub saying the merge commit cannot be made');
});

test('PullState_FailingChecksAndChangesRequested_ChecksFailing', () => {
  assert.equal(pullState(ready({ reviewDecision: 'CHANGES_REQUESTED', checks: { passed: 1, failed: 1, pending: 0 } })), 'checks-failing', 'because a red build is fixed before the review is answered');
});

test('PullState_ChangesRequestedWithPendingChecks_ChangesRequested', () => {
  assert.equal(pullState(ready({ reviewDecision: 'CHANGES_REQUESTED', checks: { passed: 1, failed: 0, pending: 1 } })), 'changes-requested', 'because a reviewer asked for changes whatever the running check says');
});

test('PullState_NoDecisionWithChangesRequestedReview_ChangesRequested', () => {
  assert.equal(pullState(ready({ reviewDecision: null, changesRequested: 1 })), 'changes-requested', 'because an explicit request for changes blocks even where no review is required');
});

test('PullState_PendingChecks_ChecksPending', () => {
  assert.equal(pullState(ready({ checks: { passed: 2, failed: 0, pending: 1 } })), 'checks-pending', 'because a check is still running');
});

test('PullState_ReviewRequired_ReviewPending', () => {
  assert.equal(pullState(ready({ reviewDecision: 'REVIEW_REQUIRED', mergeState: 'BLOCKED' })), 'review-pending', 'because the repository still requires an approval');
});

test('PullState_ApprovedWithUnresolvedThread_Approved', () => {
  assert.equal(pullState(ready({ unresolvedThreads: 1 })), 'approved', 'because an open thread still waits for an answer');
});

test('PullState_ApprovedButMergeabilityUnknown_Approved', () => {
  assert.equal(pullState(ready({ mergeable: 'UNKNOWN', mergeState: 'UNKNOWN' })), 'approved', 'because GitHub has not yet said the pull merges cleanly');
});

test('PullState_ApprovedButBlocked_Approved', () => {
  assert.equal(pullState(ready({ mergeState: 'BLOCKED' })), 'approved', 'because a branch rule still stops the merge');
});

test('PullState_NoReviewRequiredButBehind_Approved', () => {
  assert.equal(pullState(ready({ reviewDecision: null, mergeState: 'BEHIND' })), 'approved', 'because the branch must take the base before it can merge');
});

test('FixturePulls_EachStopsAtItsOwnState', async () => {
  const states = Object.fromEntries((await snapshot()).pulls.map((pull) => [pull.number, pull.state]));
  assert.deepEqual(states, { 560: 'checks-failing', 20: 'mergeable', 21: 'changes-requested', 22: 'draft', 23: 'approved' }, 'because each fixture pull stops at a different step of the precedence');
});

test('Pulls_ItemPrUrl_LinksItem', async () => {
  assert.equal(pullNumbered(await snapshot(), 20)?.item, 'gh#20', 'because the issue state names the pull by URL');
});

test('Pulls_ItemPrUrlOtherCaseAndScheme_LinksItem', async () => {
  const facts = withBoardItem(await input(), 'gh#20', { pr: 'http://EXAMPLE/pull/20/' });
  assert.equal(pullNumbered(reconcile(facts), 20)?.item, 'gh#20', 'because host and path compare without case and either scheme names the same pull');
});

test('Pulls_ItemPrNumber_LinksItemBeforeBranch', async () => {
  const facts = withBoardItem(await input(), 'gh#12', { pr: '#21' });
  assert.equal(pullNumbered(reconcile(facts), 21)?.item, 'gh#12', 'because the item that names the pull wins over a branch that happens to match');
});

test('Pulls_ItemPrUrlOfAnotherRepo_NoLink', async () => {
  const facts = withBoardItem(await input(), 'gh#20', { pr: 'https://elsewhere/pull/20' });
  assert.equal(pullNumbered(reconcile(facts), 20)?.item, null, 'because the same number in another repository is another pull');
});

test('Pulls_ClaimBranch_LinksItemAndWorktree', async () => {
  const twentyOne = pullNumbered(await snapshot(), 21);
  assert.deepEqual([twentyOne?.item, twentyOne?.worktree], ['gh#9', 'project-wt-3'], 'because the pull head is the branch claimed in project-wt-3');
});

test('Pulls_ForkOnClaimedBranchName_NoLink', async () => {
  assert.equal(pullNumbered(await snapshot(), 23)?.item, null, 'because a fork branch named like a claim is someone else\'s branch');
});

test('OpenedAndUpdatedTimes_GiveAgeAndIdleSeconds', async () => {
  const twenty = pullNumbered(await snapshot(), 20);
  assert.deepEqual([twenty?.ageSeconds, twenty?.idleSeconds], [375364, 22564], 'because it was opened at 10:00 four days before now and last touched at noon today');
});

test('Attention_PullRows_FailingChangesRequestedMergeable', async () => {
  const rows = (await snapshot()).attention.filter((row) => row.kind.startsWith('pr-'));
  assert.deepEqual(rows.map((row) => [row.kind, row.id]).sort(), [['pr-changes-requested', 'gh#9'], ['pr-failing', '#560'], ['pr-mergeable', 'gh#20']], 'because a draft or a blocked pull asks for nothing, and each other row names its item, or the pull when no item has it');
});

test('Attention_MergeablePull_ReadyToMerge', async () => {
  const row = (await snapshot()).attention.find((entry) => entry.kind === 'pr-mergeable');
  assert.equal(row?.title, '#20 ready to merge', 'because the row tells you what to do');
});

test('Disagreement_DonePullMergeableNoMergeGate_Raised', async () => {
  assert.equal(mergeDisagreements(await snapshot())[0]?.item, 'gh#20', 'because gh#20 is done and its PR is ready, yet no merge gate asks for it');
});

test('Disagreement_DonePullMergeableWithMergeGate_None', async () => {
  const facts = withBoardItem(await input(), 'gh#20', { gate: 'merge' });
  assert.deepEqual(mergeDisagreements(reconcile(facts)), [], 'because the merge gate already asks you to merge it');
});

test('Disagreement_DonePullNotMergeable_None', async () => {
  const facts = await input();
  facts.pulls = { pulls: (facts.pulls?.pulls ?? []).map((pull) => (pull.number === 20 ? { ...pull, unresolvedThreads: 1 } : pull)) };
  assert.deepEqual(mergeDisagreements(reconcile(facts)), [], 'because a pull with an open thread is not ready, so nothing is missing a merge gate');
});

test('Disagreement_PullsUnreadDoneItemNamesPr_Raised', async () => {
  const facts = await input();
  facts.pulls = null;
  assert.equal(mergeDisagreements(reconcile(facts))[0]?.item, 'gh#20', 'because without pull requests the issue naming a PR is the evidence it waits on a merge');
});

test('Disagreement_PullsUnreadClosedItem_None', async () => {
  const facts = await input();
  facts.pulls = null;
  assert.equal(mergeDisagreements(reconcile(facts)).some((entry) => entry.item === 'gh#2'), false, 'because a closed item has nothing left to merge');
});

test('FixturePulls_CountedByState', async () => {
  const { counts } = await snapshot();
  assert.deepEqual([counts.pullsMergeable, counts.pullsFailing, counts.pullsChangesRequested], [1, 1, 1], 'because the fixture holds one ready, one failing and one with changes requested');
});

const withExtraBoardItem = (facts: ReconcileInput, change: Partial<BoardItem>): ReconcileInput => {
  const template = (facts.board?.items ?? []).find((item) => item.id === 'gh#12')!;
  return { ...facts, board: { items: [...(facts.board?.items ?? []), { ...template, id: 'gh#14', title: 'Fourteen', priority: '', needs: ['priority'], url: 'https://example/14', parent: 'gh#7', ...change }], bodies: facts.board?.bodies ?? {} } };
};
/** Adds board items made from gh#12's shape, one per change. */
const withBoardItems = (facts: ReconcileInput, changes: Partial<BoardItem>[]): ReconcileInput => {
  const template = (facts.board?.items ?? []).find((item) => item.id === 'gh#12')!;
  return { ...facts, board: { items: [...(facts.board?.items ?? []), ...changes.map((change) => ({ ...template, ...change }))], bodies: facts.board?.bodies ?? {} } };
};
const needsFieldIds = (picture: Snapshot): string[] => picture.attention.filter((row) => row.kind === 'needs-field').map((row) => row.id);
const disagreementOf = (picture: Snapshot, sources: string) => picture.disagreements.find((entry) => entry.sources.join(' vs ') === sources);

test('Worktree_CodexDesktopServerInIt_NoSession', async () => {
  const stale = worktree(await snapshot(), 'project-wt-4');
  assert.deepEqual([stale?.sessions, stale?.flags.includes('session')], [[], false], 'because the Codex app-server and its pid loop sit in the folder but nobody types into them');
});

test('Worktree_Agent_PidHostCommandAndElapsed', async () => {
  const [agent] = worktree(await snapshot(), 'project-wt-3')?.agents ?? [];
  assert.deepEqual(agent, { pid: 100, host: 'claude', command: '/usr/local/bin/claude -p /flow:next gh#9 --permission-mode auto', elapsedSeconds: 942, session: null }, 'because the card says which host runs, what it was asked and for how long, and no transcript is found without a session locator');
});

test('Worktree_BehindAndIdle_StaleReasonNamesBoth', async () => {
  assert.equal(worktree(await snapshot(), 'project-wt-4')?.staleReason, 'branch is 35 commits behind main (limit 20); claimed 6 days ago with no run, agent or gate', 'because the owner must see why the worktree is stale before acting on it');
});

test('Worktree_NotStale_NoReason', async () => {
  assert.equal(worktree(await snapshot(), 'project-wt-3')?.staleReason, null, 'because a running worktree has nothing to explain');
});

test('Attention_StaleRow_CarriesTheReason', async () => {
  const row = (await snapshot()).attention.find((entry) => entry.kind === 'stale');
  assert.equal(row?.detail, worktree(await snapshot(), 'project-wt-4')?.staleReason, 'because the needs-you list and the card give the same reason');
});

test('Worktree_ItemOnBoard_ItemUrlAndTitle', async () => {
  const gated = worktree(await snapshot(), 'project-wt-2');
  assert.deepEqual([gated?.itemUrl, gated?.itemTitle], ['https://example/7', 'Seven'], 'because the pool map links and names the item without a lookup');
});

test('Worktree_ItemNotOnBoard_NoUrlOrTitle', async () => {
  const stale = worktree(await snapshot(), 'project-wt-4');
  assert.deepEqual([stale?.itemUrl, stale?.itemTitle], [null, null], 'because the board never listed gh#5, so nothing is known about it');
});

test('NeedsField_OpenUnstartedUnblocked_AttentionRow', async () => {
  const row = reconcile(withExtraBoardItem(await input(), {})).attention.find((entry) => entry.kind === 'needs-field');
  assert.deepEqual([row?.id, row?.detail], ['gh#14', 'needs priority'], 'because the next job refuses an item with no priority and nobody would know why it sits');
});

test('NeedsField_TwoFields_BothNamed', async () => {
  const row = reconcile(withExtraBoardItem(await input(), { needs: ['priority', 'size'] })).attention.find((entry) => entry.kind === 'needs-field');
  assert.equal(row?.detail, 'needs priority and size', 'because the owner fills every missing field in one visit');
});

test('NeedsField_ChildOfASplitParentWithADoneSibling_Row', async () => {
  const facts = withBoardItems(await input(), [
    { id: 'gh#341', kind: 'task', title: 'Split parent', needs: [], parent: '' },
    { id: 'gh#544', title: 'First half', status: 'closed', parent: 'gh#341', state: { step: 'done', gate: 'none', worktree: '', pr: '', last_event: '', profile: '', attempts: 0 } },
    { id: 'gh#545', title: 'Second half', priority: '', needs: ['priority'], parent: 'gh#341' },
  ]);
  assert.deepEqual(needsFieldIds(reconcile(facts)), ['gh#545'], 'because its sibling is done, so this is the next step of work already under way and only the missing priority stops it');
});

test('NeedsField_BlocksAnItemInProgress_Row', async () => {
  const facts = withBoardItems(withBoardItem(await input(), 'gh#9', {}), [{ id: 'gh#14', title: 'Fourteen', priority: '', needs: ['priority'], parent: '' }]);
  const blocking = { ...facts, board: { items: (facts.board?.items ?? []).map((item) => (item.id === 'gh#9' ? { ...item, blocked_by: ['gh#14'] } : item)), bodies: {} } };
  assert.deepEqual(needsFieldIds(reconcile(blocking)), ['gh#14'], 'because gh#9 is being worked and waits on it');
});

test('NeedsField_BacklogWithNoWorkUnderWay_NoRowButCountedAsWaitingOnField', async () => {
  const picture = reconcile(withExtraBoardItem(await input(), { parent: '' }));
  assert.deepEqual([needsFieldIds(picture), picture.readiness.waitingOnField, picture.readiness.nextInLineMissingField, picture.counts.needsField], [[], 1, 0, 0], 'because a backlog item lacking a priority is not news; only the ones that hold up started work get a row');
});

test('Readiness_NextInLine_CountedInBoth', async () => {
  const { readiness } = reconcile(withExtraBoardItem(await input(), {}));
  assert.deepEqual([readiness.waitingOnField, readiness.nextInLineMissingField], [1, 1], 'because the child of started work is both backlog lacking a field and the next step of that work');
});

test('NeedsField_BlockedItem_NoRow', async () => {
  const { attention } = await snapshot();
  assert.equal(attention.some((entry) => entry.kind === 'needs-field'), false, 'because gh#13 lacks a size but waits on gh#12 first, so only the head of its chain asks');
});

test('NeedsField_ItemWithAStep_NoRow', async () => {
  const facts = withExtraBoardItem(await input(), { state: { step: 'plan', gate: 'none', worktree: '', pr: '', last_event: '', profile: '', attempts: 0 } });
  assert.equal(reconcile(facts).counts.needsField, 0, 'because a started item is past the ready check');
});

test('NeedsField_Counted', async () => {
  assert.equal(reconcile(withExtraBoardItem(await input(), {})).counts.needsField, 1, 'because the tile counts the rows');
});

test('Readiness_Fixture_OneBucketPerOpenItem', async () => {
  assert.deepEqual((await snapshot()).readiness, { ready: 1, waitingOnField: 0, blocked: 1, gated: 2, nextInLineMissingField: 0 }, 'because gh#12 is ready, gh#13 is blocked, gh#7 waits at a gate, gh#20 ran every step and waits on its owner, and the running and stale items are in none');
});

test('Readiness_ItemWaitingOnField_Counted', async () => {
  assert.equal(reconcile(withExtraBoardItem(await input(), {})).readiness.waitingOnField, 1, 'because gh#14 can start once it has a priority');
});

test('NeedsField_Epic_NoRow', async () => {
  assert.equal(reconcile(withExtraBoardItem(await input(), { kind: 'epic' })).counts.needsField, 0, 'because the next job takes an epic\'s tasks, never the epic, so its empty field stops nothing');
});

test('Readiness_Epic_NotCounted', async () => {
  assert.equal(reconcile(withExtraBoardItem(await input(), { kind: 'epic' })).readiness.waitingOnField, 0, 'because the next job takes an epic\'s tasks, never the epic');
});

test('Gate_ItemNamesAnOpenPull_PullWithThreads', async () => {
  const gate = reconcile(withBoardItem(await input(), 'gh#7', { pr: '560' })).gates[0];
  assert.deepEqual(gate?.pull, { number: 560, url: 'https://github.com/FJ2K/foosbrawl/pull/560', state: 'checks-failing', unresolvedThreads: 1 }, 'because the card shows the review thread the merge still waits on');
});

const gateOn = (facts: ReconcileInput, item: string): ReconcileInput => ({ ...facts, flow: { ...facts.flow, gates: facts.flow.gates.map((gate) => ({ ...gate, item })) } });

test('Gate_PullOnlyOnTheClaimedBranch_ThatPull', async () => {
  assert.equal(reconcile(gateOn(await input(), 'gh#9')).gates[0]?.pull?.number, 21, 'because gh#9 names no pull and #21 is open on its claimed branch');
});

test('Gate_NamedPullAndBranchPull_TheNamedOne', async () => {
  const facts = withBoardItem(gateOn(await input(), 'gh#9'), 'gh#9', { pr: '#22' });
  assert.equal(reconcile(facts).gates[0]?.pull?.number, 22, 'because the pull the item names wins over one that happens to sit on its branch, even when the branch pull is listed first');
});

test('Gate_ItemWithoutPull_NoPull', async () => {
  assert.equal((await snapshot()).gates[0]?.pull, null, 'because gh#7 names no pull and no pull is on its branch');
});

test('Project_GithubAdapter_RepoAndIssuesUrls', async () => {
  const { project } = await snapshot();
  assert.deepEqual([project.repoUrl, project.trackerUrl, project.jobsHost], ['https://github.com/example/fixture', 'https://github.com/example/fixture/issues', 'claude'], 'because the header links the repository and the tracker and says which CLI the jobs run');
});

test('Project_LocalAdapter_NoTrackerUrl', async () => {
  const facts = await input();
  facts.flow.config.adapter = 'local';
  assert.equal(reconcile(facts).project.trackerUrl, null, 'because the local tracker has no page to open');
});

test('Disagreement_GateVsLabels_ExplainedWithReReadTheBoard', async () => {
  const found = disagreementOf(await snapshot(), 'gate record vs issue labels');
  assert.equal(found?.explain, 'A gate record says gh#7 waits on you at the ambiguity gate, while the issue labels show no gate; the gate record is usually right, and the labels catch up when the board is read again.', 'because the owner needs to know which store to trust');
  assert.deepEqual(found?.action, { kind: 'refresh', args: { source: 'board' }, label: 'Re-read the board' }, 'because the labels are usually only late');
});

test('Disagreement_DoneAndMergeable_ActionMergesThePull', async () => {
  assert.deepEqual(disagreementOf(await snapshot(), 'issue state vs pull request')?.action, { kind: 'pr.merge', args: { pr: '20' }, label: 'Merge #20' }, 'because the only thing left is the merge');
});

test('Disagreement_PullsUnreadDoneItem_NoMergeButton', async () => {
  const facts = await input();
  facts.pulls = null;
  const found = disagreementOf(reconcile(facts), 'issue state vs pull request');
  assert.deepEqual([found?.item, found?.action], ['gh#20', null], 'because without pull requests read nothing says the named PR is open, green or even in this repository, so the row shows but no button merges it');
});

/** gh#9 (claimed in project-wt-3 at step implement) with the issue at step review and no run of it going. */
async function stepMismatchNoRun(): Promise<ReconcileInput> {
  const facts = withBoardItem(await input(), 'gh#9', { step: 'review' });
  facts.flow.runs = [];
  facts.processes = { agents: [] };
  return facts;
}
const stepMismatchOf = (picture: Snapshot) => picture.disagreements.find((entry) => entry.sources.join(' vs ') === 'claim vs issue state' && entry.message.includes('the claim says step'));

test('Disagreement_ClaimStepVsIssue_ActionSetsTheIssueStep', async () => {
  const found = stepMismatchOf(reconcile(await stepMismatchNoRun()));
  assert.deepEqual(found?.action, { kind: 'item.step-sync', args: { item: 'gh#9' }, label: "Set the issue's step to the claim's" }, "because with no run going the claim is the agent's last word on the step, and the issue can be set to it");
  assert.equal(found?.explain, "The claim in project-wt-3 says gh#9 is at step implement, while the issue says review; the claim is usually right, because it is the agent's own record and is written first, and the button writes step implement to the issue as the flow does at a step change.", 'because the owner must know which store to trust and what the button does');
});

test('Disagreement_ClaimAtSyncStep_NoAction', async () => {
  const facts = await stepMismatchNoRun();
  facts.flow.claims = facts.flow.claims.map((claim) => (claim.item === 'gh#9' ? { ...claim, step: 'sync' } : claim));
  const found = stepMismatchOf(reconcile(facts));
  assert.deepEqual([found?.item, found?.action], ['gh#9', null], "because the sync step runs ahead of the item's own step and never moves it, so writing sync to the issue would be wrong");
});

/** Read marks: `started` reads handed out, with the files' and the board's latest good reads having started at the numbers given. */
const readMarks = (started: number, files: number, board: number): ReadMarks => ({
  started, completed: { files, git: started, processes: started, jobs: started, board, pulls: started },
  failing: { files: false, git: false, processes: false, jobs: false, board: false, pulls: false },
});
const settledWith = (settler: DisagreementSettler, facts: ReconcileInput, marks: ReadMarks): Snapshot => reconcile({ ...facts, settle: (found) => settler.settle(found, marks) });

test('Lag_StepMismatchWhileARunGoes_Hidden', async () => {
  const live = withBoardItem(await input(), 'gh#9', { step: 'review' });
  const recordOnly = { ...live, processes: { agents: [] } };
  const processOnly = { ...live, flow: { ...live.flow, runs: [] } };
  for (const [facts, because] of [[live, 'a run record and an agent'], [recordOnly, 'a run record'], [processOnly, 'an agent in its worktree']] as const) {
    const settler = new DisagreementSettler();
    settledWith(settler, facts, readMarks(10, 10, 9));
    assert.equal(stepMismatchOf(settledWith(settler, facts, readMarks(20, 20, 20))), undefined, `because with ${because} the run moves the step itself and the issue lags it`);
  }
});

test('Lag_RunEnded_HiddenUntilABoardReadStartedAfterTheEnd', async () => {
  const live = withBoardItem(await input(), 'gh#9', { step: 'review' });
  const ended = await stepMismatchNoRun();
  const settler = new DisagreementSettler();
  settledWith(settler, live, readMarks(10, 10, 9));
  settledWith(settler, live, readMarks(11, 11, 10));
  assert.equal(stepMismatchOf(settledWith(settler, ended, readMarks(12, 12, 10))), undefined, 'because the run just ended and the issue may not have caught up');
  assert.equal(stepMismatchOf(settledWith(settler, ended, readMarks(14, 14, 11))), undefined, 'because the board read that finished started (as read 11) before the run was seen to end, so it may hold the old step');
  assert.equal(stepMismatchOf(settledWith(settler, ended, readMarks(15, 15, 13)))?.action?.kind, 'item.step-sync', 'because a board read that started after the run ended still says the other step, so it is a disagreement');
});

test('Lag_StepMismatchWithoutAnyRun_FollowsTheSettleRule', async () => {
  const facts = await stepMismatchNoRun();
  const settler = new DisagreementSettler();
  assert.equal(stepMismatchOf(settledWith(settler, facts, readMarks(6, 6, 5))), undefined, 'because one picture cannot tell it from a board that lags a read');
  assert.equal(stepMismatchOf(settledWith(settler, facts, readMarks(8, 7, 8)))?.item, 'gh#9', 'because the claim and the issue were both read again after it appeared and still disagree');
});

test('Disagreement_DeadRun_ActionRunsHealth', async () => {
  const facts = await input();
  facts.processes = { agents: [] };
  assert.equal(disagreementOf(reconcile(facts), 'run record vs process list')?.action?.kind, 'steward.health', 'because the health job clears a run record whose process is gone');
});

test('Settle_HoldsBack_NotInListCountOrAttention', async () => {
  const picture = reconcile({ ...(await input()), settle: () => [] });
  assert.deepEqual([picture.disagreements, picture.counts.disagreements, picture.attention.some((row) => row.kind === 'disagreement')], [[], 0, false], 'because a disagreement held back is not shown anywhere yet');
});

test('Worktree_SyncNoteOfItsClaim_ShownAsSyncPending', async () => {
  const picture = await snapshot();
  assert.deepEqual([worktree(picture, 'project-wt-2')?.syncPending, worktree(picture, 'project-wt-3')?.syncPending], [['origin/flow/gh-7', 'origin/main'], null], 'because a note the health job wrote must show on the card, not only one the console wrote');
});

test('GateItemWithABody_GateCarriesIt', async () => {
  const facts = await input();
  const picture = reconcile({ ...facts, board: { items: facts.board?.items ?? [], bodies: { 'gh#7': '## Spec' } } });
  assert.equal(picture.gates.find((gate) => gate.item === 'gh#7')?.body, '## Spec', 'because the card shows the issue the gate is about');
});

test('BoardJson_KeepsBodiesApartFromItems', () => {
  const board = parseBoard(JSON.stringify({ items: [{ id: 'gh#1', status: 'open', blocked_by: [], body: 'text' }] }));
  assert.deepEqual([board.bodies, 'body' in board.items[0]!], [{ 'gh#1': 'text' }, false], 'because only gates carry a body, not every item on every snapshot');
});

