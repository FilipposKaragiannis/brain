import assert from 'node:assert/strict';
import path from 'node:path';
import { test } from 'node:test';
import type { BoardItem } from '../src/collectors/board.ts';
import { parseBoard } from '../src/collectors/board.ts';
import { readFlowHome } from '../src/collectors/flowHome.ts';
import { readGit } from '../src/collectors/git.ts';
import { parseJobStatus } from '../src/collectors/jobs.ts';
import { readProcesses } from '../src/collectors/processes.ts';
import type { ProcessFacts } from '../src/collectors/processes.ts';
import type { PullFact } from '../src/collectors/pulls.ts';
import { readPulls } from '../src/collectors/pulls.ts';
import { landedMergeGates, pullState, reconcile, runOutcome, runReason } from '../src/reconcile.ts';
import type { ReconcileInput } from '../src/reconcile.ts';
import { DisagreementSettler } from '../src/settle.ts';
import type { ReadMarks } from '../src/settle.ts';
import type { JobRunRecord, JobStatusRow } from '../src/collectors/jobs.ts';
import type { Freshness, Snapshot } from '../src/snapshot.ts';
import { JOB_RUNS_KEPT } from '../src/snapshot.ts';
import { BOARD_JSON, FIXTURE_ROOT, JOBS_JSON, LOCAL_BOARD_JSON, fakeRunner } from './fakeRunner.ts';

const NOW = new Date('2026-10-24T18:16:04Z');
const fresh: Freshness = { at: NOW.toISOString(), ageSeconds: 0, ok: true, error: null };

async function input(): Promise<ReconcileInput> {
  return {
    now: NOW,
    project: { id: 'project', name: 'project', root: FIXTURE_ROOT },
    flow: await readFlowHome(FIXTURE_ROOT, fakeRunner),
    git: await readGit(FIXTURE_ROOT, 'main', fakeRunner),
    processes: await readProcesses(fakeRunner, () => NOW),
    jobs: { jobs: parseJobStatus(JOBS_JSON), runs: [] },
    board: parseBoard(BOARD_JSON),
    pulls: await readPulls(FIXTURE_ROOT, 'example/fixture', fakeRunner, NOW),
    sources: { files: fresh, git: fresh, processes: fresh, jobs: fresh, board: fresh, pulls: fresh },
  };
}

async function snapshot(): Promise<Snapshot> { return reconcile(await input()); }

const worktree = (picture: Snapshot, name: string) => picture.worktrees.find((entry) => entry.name === name);

/** A process read that worked and found no claude, codex or unattended loop at all. */
const NOTHING_RUNS: ProcessFacts = { agents: [], servers: [], hosts: [], list: { status: 'complete' } };

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

/** The fixture with project-wt-4 (35 behind main, claimed six days ago) reserved by the owner instead. */
async function reservedFarBehind(): Promise<Snapshot> {
  const facts = await input();
  facts.flow = { ...facts.flow, claims: facts.flow.claims.map((claim) => (claim.worktreePath.endsWith('project-wt-4') ? { ...claim, item: '', branch: '', step: '', reserved: 'Ada Lovelace' } : claim)) };
  return reconcile(facts);
}

test('ReservedWorktreeFarBehindAndOld_IsNotStale', async () => {
  assert.equal(worktree(await reservedFarBehind(), 'project-wt-4')?.state, 'claimed', "because a reservation is the owner's own work, which the console does not judge idle or behind");
});

test('ReservedWorktree_HasNoItem', async () => {
  assert.equal(worktree(await reservedFarBehind(), 'project-wt-4')?.item, null, 'because a reservation claims no item, so the card links none');
});

test('ReservedWorktree_ClaimSaysWhoReservedIt', async () => {
  assert.equal(worktree(await reservedFarBehind(), 'project-wt-4')?.claim?.reserved, 'Ada Lovelace', 'because the card names who holds the worktree');
});

test('MainAndSideWorktrees_AreOutsideThePool', async () => {
  const picture = await snapshot();
  assert.equal(worktree(picture, 'project')?.role, 'main', 'because the root is the flow home');
  assert.equal(worktree(picture, 'project-side')?.state, 'outside', 'because git lists it but the pool does not');
});

test('Counts_FollowPoolStates', async () => {
  const { counts } = await snapshot();
  assert.equal(counts.agents, 1, 'because a session is not an agent');
  assert.deepEqual([counts.running, counts.stale, counts.free], [1, 1, 0], 'because the pool holds one of each and nothing free');
  assert.equal(counts.needsYou, 2, "because gh#7 waits at a gate and gh#20 ran every step with no merge gate, so it is the owner's to close");
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

test('GateOfAnItemWithAQuiz_CarriesTheQuizAndItsLastTry', async () => {
  const [gate] = (await snapshot()).gates;
  assert.equal(gate?.quiz?.questions.length, 2, 'because the Gates page offers the quiz the explain step wrote in the claimed worktree');
  assert.equal(gate?.quiz?.result?.right, 1, 'because the owner sees how the last try went');
});

/** The fixture's pulls with gh#7, whose worktree holds a quiz, naming pull 23 as its PR. */
async function pullsWithTheQuizItemNamingPull23(): Promise<Snapshot['pulls']> {
  const facts = await input();
  const seven = facts.board!.items.find((item) => item.id === 'gh#7')!;
  seven.state = { ...seven.state, pr: 'https://example/pull/23' };
  return reconcile(facts).pulls;
}

test('Pull_NamedByAnItemWithAQuiz_CarriesTheQuiz', async () => {
  const pulls = await pullsWithTheQuizItemNamingPull23();
  assert.equal(pulls.find((pull) => pull.number === 23)?.quiz?.title, 'Quiz for gh#7', 'because the pull the item names is the item\'s, so its card offers the quiz');
});

/** The fixture with gh#7, claimed in project-wt-2 where an interactive claude sits, naming pull 23 as its open PR. */
async function sessionBesideItsItemsOpenPull(): Promise<Snapshot> {
  const facts = await input();
  const seven = facts.board!.items.find((item) => item.id === 'gh#7')!;
  seven.state = { ...seven.state, pr: 'https://example/pull/23' };
  return reconcile(facts);
}

test('PoolWorktreeWithASessionAndItsItemsOpenPull_CommentsSkipped', async () => {
  assert.ok(worktree(await sessionBesideItsItemsOpenPull(), 'project-wt-2')?.flags.includes('comments-skipped'), "because flow's comments job never edits under a session, so it skips the item's PR while one works there");
});

test('PoolWorktreeWithASessionAndNoOpenPull_NotCommentsSkipped', async () => {
  assert.equal(worktree(await snapshot(), 'project-wt-2')?.flags.includes('comments-skipped'), false, 'because the only pull on its branch is a fork, so the comments job has no PR of the item to skip');
});

test('PoolWorktreeWithAnOpenPullAndNoSession_NotCommentsSkipped', async () => {
  assert.equal(worktree(await snapshot(), 'project-wt-3')?.flags.includes('comments-skipped'), false, 'because nobody types in it, so the comments job addresses pull 21 there');
});

test('Pull_WithNoItem_NoQuiz', async () => {
  const pulls = await pullsWithTheQuizItemNamingPull23();
  assert.equal(pulls.find((pull) => pull.number === 22)?.quiz, null, 'because a pull with no item has no quiz');
});

test('Pull_ForkBranchNamedLikeTheClaim_NoQuiz', async () => {
  assert.equal((await snapshot()).pulls.find((pull) => pull.number === 23)?.quiz, null, 'because a fork branch named like the claim is not the item\'s pull, so it gets no quiz either');
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

/** gh#9, claimed in project-wt-3, between steps: its run ended, no process works anywhere, and the board's state of it changed as given. */
async function parkedNine(change: Partial<BoardItem['state']> = {}, claimedAt: string | null = null): Promise<ReconcileInput> {
  const facts = withBoardItem(await input(), 'gh#9', change);
  facts.processes = NOTHING_RUNS;
  facts.flow = {
    ...facts.flow, runs: [],
    claims: facts.flow.claims.map((claim) => (claim.item === 'gh#9' && claimedAt !== null ? { ...claim, claimedAt } : claim)),
  };
  return facts;
}
const HELD = { held_by: 'gh#12', held_reason: 'shares src/ui/board.ts, which gh#12 changes' };
const SIX_DAYS_BEFORE = '2026-10-18T18:00:00Z';

test('ParkedClaim_NotHeld_WaitingForAWorker', async () => {
  const picture = reconcile(await parkedNine());
  assert.equal(worktree(picture, 'project-wt-3')?.state, 'waiting', 'because a claim with no run, no agent and no gate is parked until a worker takes its next step, not work going on');
  assert.equal(picture.items.find((item) => item.id === 'gh#9')?.state, 'waiting', 'because the Board must not show a parked item as live work');
  assert.deepEqual([picture.counts.waiting, picture.counts.claimed], [1, 0], 'because the pool counts it as waiting, not as a bare claim');
});

test('ParkedClaim_PluginBeforeTheHoldKeys_NotHeld', async () => {
  const nine = worktree(reconcile(await parkedNine()), 'project-wt-3');
  assert.deepEqual([nine?.heldBy, nine?.heldReason], [null, null], 'because a state without held_by holds nothing');
});

test('ParkedClaim_Held_HeldBehindItsHolderWithTheReason', async () => {
  const picture = reconcile(await parkedNine(HELD));
  const nine = worktree(picture, 'project-wt-3');
  assert.deepEqual([nine?.state, nine?.heldBy, nine?.heldReason], ['held', 'gh#12', HELD.held_reason], 'because the card says which item it waits behind and why');
  const item = picture.items.find((entry) => entry.id === 'gh#9');
  assert.deepEqual([item?.state, item?.heldBy, item?.heldReason], ['held', 'gh#12', HELD.held_reason], 'because the Board says the same as the card');
  assert.equal(picture.counts.held, 1, 'because the pool counts the held worktree');
});

test('ParkedClaim_HolderClosedOnTheBoard_WaitingNotHeld', async () => {
  const facts = withBoardItems(await parkedNine({ held_by: 'gh#40', held_reason: 'shares src/a.ts' }), [{ id: 'gh#40', status: 'closed' }]);
  const picture = reconcile(facts);
  const nine = worktree(picture, 'project-wt-3');
  assert.deepEqual([nine?.state, nine?.heldBy], ['waiting', null], "because flow's ready filter lets an item through once its holder closes, and next.sh lifts the tag on its next run");
  assert.equal(picture.items.find((item) => item.id === 'gh#9')?.state, 'waiting', 'because the Board says the same as the card');
});

test('ParkedClaim_HolderNotOnTheBoard_StillHeld', async () => {
  const nine = worktree(reconcile(await parkedNine({ held_by: 'gh#41', held_reason: 'shares src/a.ts' })), 'project-wt-3');
  assert.deepEqual([nine?.state, nine?.heldBy], ['held', 'gh#41'], 'because a holder the board does not list may still be open, so the hold stands as flow wrote it');
});

test('HeldClaimSixDaysOld_NotIdle', async () => {
  const nine = worktree(reconcile(await parkedNine(HELD, SIX_DAYS_BEFORE)), 'project-wt-3');
  assert.equal(nine?.state, 'held', 'because a held claim waits on purpose, for its holder to close');
  assert.equal(nine?.flags.includes('idle'), false, 'because its age alone says nothing went wrong');
});

test('FreeClaimSixDaysOld_StillStale', async () => {
  assert.equal(worktree(reconcile(await parkedNine({}, SIX_DAYS_BEFORE)), 'project-wt-3')?.state, 'stale', 'because a claim nothing holds back and nobody worked for six days is idle');
});

test('ItemHeldWithNoWorktree_HeldNotReady', async () => {
  const picture = reconcile(withBoardItem(await input(), 'gh#12', HELD));
  assert.equal(picture.items.find((item) => item.id === 'gh#12')?.state, 'held', "because flow's ready filter skips a held item until its holder closes");
  assert.deepEqual([picture.readiness.ready, picture.readiness.held], [0, 1], 'because the readiness line must not offer a held item to the next job');
});

test('ItemsByState_ParkedAfterLiveWorkBeforeUnstarted', async () => {
  const picture = reconcile(withBoardItem(await parkedNine(HELD), 'gh#12', {}));
  const order = picture.items.map((item) => item.state);
  assert.ok(order.indexOf('held') > order.indexOf('stale') && order.indexOf('held') < order.indexOf('ready'), 'because parked work sorts after live work and before what nothing has started');
});

test('ItemsToClose_ListedWithWhatToDo', async () => {
  const facts = withBoardItems(await input(), [
    { id: 'gh#40', title: 'Forty', state: { step: 'done', gate: 'none', worktree: '', pr: '', last_event: '2026-10-22T09:00:00Z implement done; every step ran', profile: 'task-S', attempts: 0 } },
    { id: 'gh#41', title: 'Forty-one', state: { step: 'split', gate: 'none', worktree: '', pr: '', last_event: '', profile: 'task-M', attempts: 0 }, open_children: 2 },
    { id: 'gh#42', title: 'Forty-two', state: { step: 'split', gate: 'none', worktree: '', pr: '', last_event: '', profile: 'task-M', attempts: 0 }, open_children: 0 },
  ]);
  const picture = reconcile(facts);
  const todo = Object.fromEntries(picture.toClose.map((entry) => [entry.item, entry.todo]));
  assert.equal(todo['gh#42'], 'Every child is closed: close the parent.', 'because no gate asks the owner to close a split item whose children are done');
  assert.equal(todo['gh#40'], 'Every step ran: merge or close.', 'because no merge gate asks about an item every step of which ran');
  assert.equal('gh#41' in todo, false, 'because a split item with open children waits on them, not on the owner');
  assert.equal(picture.toClose.find((entry) => entry.item === 'gh#40')?.sinceAt, '2026-10-22T09:00:00Z', "because the wait counts from the item's last flow event");
  assert.deepEqual(picture.attention.filter((row) => row.kind === 'close').map((row) => row.id).sort(), ['gh#20', 'gh#40', 'gh#42'], 'because the Overview lists them with the gates');
});

test('NeedsYouCount_GatesPlusItemsToClose_EveryNeedsYouItemOnce', async () => {
  const picture = reconcile(withBoardItems(await input(), [{ id: 'gh#42', state: { step: 'split', gate: 'none', worktree: '', pr: '', last_event: '', profile: 'task-M', attempts: 0 }, open_children: 0 }]));
  const listed = [...picture.gates.map((gate) => gate.item), ...picture.toClose.map((entry) => entry.item)].sort();
  assert.equal(picture.counts.needsYou, listed.length, 'because the Overview count and the Gates screen count the same rows');
  assert.deepEqual(picture.items.filter((item) => item.state === 'needs-you').map((item) => item.id).sort(), listed, 'because every item the Board tags needs you shows on the Gates screen, once');
});

test('ClaimedItemEveryStepRanNoGate_WorktreeNeedsYou', async () => {
  const picture = reconcile(await parkedNine({ step: 'done' }));
  assert.equal(worktree(picture, 'project-wt-3')?.state, 'needs-you', 'because nothing is left for a worker: the owner merges or closes it');
  assert.equal(picture.toClose.find((entry) => entry.item === 'gh#9')?.worktree, 'project-wt-3', 'because the close card names the worktree the sweep frees after');
});

test('ClaimedItemAtAMergeGateInReview_InReviewNotWaiting', async () => {
  const facts = await parkedNine({ step: 'done', gate: 'merge' });
  facts.flow = { ...facts.flow, gates: [{ item: 'gh#9', gate: 'merge', message: 'Merge #21', time: '2026-10-24T10:00:00Z', host: 'shell', questions: null, plan: null }] };
  facts.pulls = { merged: [], pulls: (facts.pulls?.pulls ?? []).map((entry) => (entry.number === 21 ? { ...entry, reviewDecision: 'CHANGES_REQUESTED' } : entry)) };
  const picture = reconcile(facts);
  assert.equal(worktree(picture, 'project-wt-3')?.state, 'claimed', 'because its gate waits on reviewers, not on a worker of the next job');
  assert.equal(picture.items.find((item) => item.id === 'gh#9')?.state, 'in-review', 'because the item waits on its reviewers, worktree or not');
  assert.equal(picture.toClose.some((entry) => entry.item === 'gh#9'), false, "because a merge gate exists for it, so it is not the owner's to close yet");
});

test('Items_EngagedFirstThenRank', async () => {
  const ids = (await snapshot()).items.map((item) => item.id);
  assert.deepEqual(ids.slice(0, 4), ['gh#7', 'gh#20', 'gh#9', 'gh#5'], 'because what needs you (a gate, or every step ran with nobody to merge or close it) comes before what runs, then stale, before the backlog');
});

test('Items_BodyDropped', async () => {
  const seven = parseBoard(BOARD_JSON).items[0] as unknown as Record<string, unknown>;
  assert.equal('body' in seven, false, 'because the snapshot must stay small');
});

test('Items_Spend_FromTheBoardOrNull', async () => {
  const spend = Object.fromEntries((await snapshot()).items.map((item) => [item.id, item.spend]));
  assert.deepEqual(spend['gh#7'], { costUsd: 1.234567, sessions: 3, tokens: 120000 }, 'because the board sums the item\'s step sessions');
  assert.deepEqual(spend['gh#9'], { costUsd: 0, sessions: 2, tokens: 50000 }, 'because codex reports no cost, yet its sessions and tokens count');
  assert.deepEqual([spend['gh#12'], spend['gh#13']], [null, null], 'because an item with no session has no spend, and a malformed entry is dropped, not shown as $0');
});

test('OlderBoard_NoSpend_ItemsHaveNone', () => {
  assert.deepEqual(parseBoard(LOCAL_BOARD_JSON).spend, {}, 'because a plugin before flow 1.22.0 prints no spend');
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
  facts.processes = NOTHING_RUNS;
  const picture = reconcile(facts);
  assert.equal(picture.runs[0]?.liveness, 'dead', 'because a full process read found no agent in the worktree and no owner, 14 minutes after the run started');
  assert.ok(worktree(picture, 'project-wt-3')?.flags.includes('dead-run'), 'because the card must say the run is a ghost');
  assert.equal(worktree(picture, 'project-wt-3')?.state, 'claimed', 'because a dead run is not running');
  assert.ok(picture.attention.some((row) => row.kind === 'dead-run'), 'because a ghost run needs a human');
});

/** The read behind the false dead runs: ps timed out, so it knows nothing about any process. */
const PS_TIMED_OUT: ProcessFacts = {
  agents: [], servers: [], hosts: [],
  list: { status: 'unavailable', reason: 'ps timed out after 10s', lookup: { command: 'ps', code: null, timedOut: true, durationMs: 10004, stderr: '' } },
};

/** The fixture's processes with lsof giving no directory for gh#9's agent (100), so ps saw it but not where it works. */
async function lsofMissedTheAgent(): Promise<ProcessFacts> {
  return readProcesses(async (request) => (request.command === 'lsof' ? { code: 0, stdout: '', stderr: '', timedOut: false } : fakeRunner(request)), () => NOW);
}

const deadClaims = (picture: Snapshot): unknown[] => [
  worktree(picture, 'project-wt-3')?.flags.includes('dead-run'),
  picture.attention.some((row) => row.kind === 'dead-run'),
  picture.disagreements.some((entry) => entry.sources.join(' vs ') === 'run record vs process list'),
];

test('ProcessListUnavailable_RunIsUnknown', async () => {
  const facts = await input();
  facts.processes = PS_TIMED_OUT;
  assert.equal(reconcile(facts).runs[0]?.liveness, 'unknown', 'because a ps that timed out cannot tell a live run from a dead one');
});

test('ProcessListUnavailable_NoDeadRunFlagRowOrDisagreement', async () => {
  const facts = await input();
  facts.processes = PS_TIMED_OUT;
  assert.deepEqual(deadClaims(reconcile(facts)), [false, false, false], 'because a failed lookup must never put a dead run on the card, on Needs you or among the disagreements');
});

test('ProcessListUnavailable_SnapshotSaysWhy', async () => {
  const facts = await input();
  facts.processes = PS_TIMED_OUT;
  const { processList } = reconcile(facts);
  assert.equal(processList.status === 'unavailable' ? processList.reason : processList.status, 'ps timed out after 10s', 'because the page shows why the process list is missing instead of a dead run');
});

test('ProcessesNotReadYet_RunIsUnknown', async () => {
  const facts = await input();
  facts.processes = null;
  assert.equal(reconcile(facts).runs[0]?.liveness, 'unknown', 'because before the first process read nothing says the run has no process');
});

test('LsofMissedTheAgent_OwnerStillRuns_RunIsAlive', async () => {
  const facts = await input();
  facts.processes = await lsofMissedTheAgent();
  const picture = reconcile(facts);
  assert.deepEqual([picture.runs[0]?.liveness, worktree(picture, 'project-wt-3')?.state], ['alive', 'running'], 'because the pid the run record names (99) still runs the unattended loop, which started before the record');
});

test('LsofMissedTheAgent_NoOwnerPid_RunIsUnknown', async () => {
  const facts = await input();
  facts.processes = await lsofMissedTheAgent();
  facts.flow.runs = facts.flow.runs.map((run) => ({ ...run, pid: null }));
  assert.equal(reconcile(facts).runs[0]?.liveness, 'unknown', 'because an agent ps listed may be working in the worktree, so its missing directory proves nothing');
});

test('FullReadNoAgentInTheWorktree_OwnerStillRuns_RunIsAlive', async () => {
  const facts = await input();
  facts.processes = { ...NOTHING_RUNS, hosts: [{ pid: 99, command: '/bin/sh /x/flow/scripts/run-unattended.sh next', startedAt: '2026-10-24T18:00:04Z' }] };
  assert.equal(reconcile(facts).runs[0]?.liveness, 'alive', 'because the owner the record names is alive, as flow\'s own liveness test finds it, wherever its worker works');
});

test('OwnerPidReusedByALaterProcess_RunIsDead', async () => {
  const facts = await input();
  facts.processes = { ...NOTHING_RUNS, hosts: [{ pid: 99, command: '/usr/local/bin/claude --session-id other', startedAt: '2026-10-24T18:10:00Z' }] };
  assert.equal(reconcile(facts).runs[0]?.liveness, 'dead', 'because the process with that pid started eight minutes after the record, so it is not the run\'s owner');
});

test('RunYoungerThanTheGrace_NoProcess_IsStarting', async () => {
  const facts = { ...(await input()), now: new Date('2026-10-24T18:06:30Z') };
  facts.processes = NOTHING_RUNS;
  const picture = reconcile(facts);
  assert.deepEqual([picture.runs[0]?.liveness, ...deadClaims(picture)], ['starting', false, false, false], 'because a run five minutes old is within the health job\'s 10m grace, which counts it as running');
});

test('Jobs_StateFromRows', async () => {
  const states = Object.fromEntries((await snapshot()).jobs.map((job) => [job.name, job.state]));
  assert.deepEqual(states, { next: 'overdue', health: 'running', retro: 'paused' }, 'because jobs.sh says next is due, which the snapshot calls overdue, health has a running entry and retro is paused');
});

test('Attention_OldestFirstWithFailedJob', async () => {
  const rows = (await snapshot()).attention;
  assert.equal(rows[0]?.kind, 'stale', 'because the six-day-old claim is the oldest thing waiting');
  assert.equal(rows[1]?.kind, 'gate', 'because the gate is two days old');
  assert.ok(rows.some((row) => row.kind === 'job-failed' && row.id === 'health'), 'because the health job exited 1 last time');
});

test('GateAttentionRow_CarriesTheGateKind', async () => {
  const row = (await snapshot()).attention.find((entry) => entry.kind === 'gate');
  assert.equal(row?.gate, 'ambiguity', 'because the row\'s chip names the gate, which a clipped title may hide');
});

test('PullAttentionRow_CarriesNoGateKind', async () => {
  const row = (await snapshot()).attention.find((entry) => entry.kind === 'pr-mergeable');
  assert.equal(row?.gate, null, 'because only a gate row has a gate kind, so every other chip names its own kind');
});

test('NoBoardYet_EngagedItemsStillListed', async () => {
  const facts = await input();
  facts.board = null;
  const ids = reconcile(facts).items.map((item) => item.id).sort();
  assert.deepEqual(ids, ['gh#5', 'gh#7', 'gh#9'], 'because claims and gates alone name the engaged items');
});

const READY: PullFact = {
  number: 30, title: 'Thirty', url: 'https://example/pull/30', branch: 'flow/gh-30', base: 'main', author: 'someone',
  draft: false, crossRepository: false, mergeable: 'MERGEABLE', mergeState: 'CLEAN', reviewDecision: 'APPROVED', changesRequested: 0, reviewsRequested: 0,
  checks: { passed: 3, failed: 0, pending: 0 }, checkRuns: [], head: null, autoMerge: null, unresolvedThreads: 0,
  createdAt: '2026-10-23T18:16:04Z', updatedAt: '2026-10-24T17:16:04Z',
};
const ready = (change: Partial<PullFact>): PullFact => ({ ...READY, ...change });
const pullNumbered = (picture: Snapshot, pullNumber: number) => picture.pulls.find((pull) => pull.number === pullNumber);
const withBoardItem = (facts: ReconcileInput, id: string, change: Partial<BoardItem['state']>): ReconcileInput => ({
  ...facts, board: { items: (facts.board?.items ?? []).map((item) => (item.id === id ? { ...item, state: { ...item.state, ...change } } : item)), bodies: facts.board?.bodies ?? {}, spend: facts.board?.spend ?? {}, trackerErrors: [] },
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

/** The facts with pull #560 opened from `branch` instead of its fixture head. */
const withPull560On = (facts: ReconcileInput, branch: string): ReconcileInput => ({
  ...facts, pulls: { merged: [], pulls: (facts.pulls?.pulls ?? []).map((pull) => (pull.number === 560 ? { ...pull, branch } : pull)) },
});

test('Pulls_NoPrRecorded_LinksTheOpenItemOnItsTaskBranch', async () => {
  const facts = withPull560On(await input(), 'flow/gh-12');
  assert.equal(pullNumbered(reconcile(facts), 560)?.item, 'gh#12', 'because flow/gh-12 is the branch the flow works gh#12 on, and gh#12 recorded no PR');
});

test('Pulls_TaskBranchSlug_ColonAndSlashBecomeDashes', async () => {
  const facts = withPull560On(await input(), 'flow/local-task-3');
  const twelve = facts.board!.items.find((item) => item.id === 'gh#12')!;
  facts.board!.items.push({ ...twelve, id: 'local:task/3' });
  assert.equal(pullNumbered(reconcile(facts), 560)?.item, 'local:task/3', 'because item_slug turns each :, / and # of the id into a dash');
});

test('Pulls_TaskBranchOfAClosedItem_NoLink', async () => {
  const facts = withPull560On(await input(), 'flow/gh-12');
  facts.board!.items.find((item) => item.id === 'gh#12')!.status = 'closed';
  assert.equal(pullNumbered(reconcile(facts), 560)?.item, null, 'because a closed item\'s branch name says nothing about an open pull');
});

test('Pulls_TaskBranchOfAnItemThatNamesAnotherPull_NoLink', async () => {
  const facts = withPull560On(await input(), 'flow/gh-20');
  assert.equal(pullNumbered(reconcile(facts), 560)?.item, null, 'because gh#20 records #20 as its PR, so a second pull on its branch name is not its');
});

test('Pulls_MergeState_CarriedAsGithubSaysIt', async () => {
  assert.equal(pullNumbered(await snapshot(), 21)?.mergeState, 'BLOCKED', 'because the card offers a force merge only where GitHub blocks the merge');
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
  facts.pulls = { merged: [], pulls: (facts.pulls?.pulls ?? []).map((pull) => (pull.number === 20 ? { ...pull, unresolvedThreads: 1 } : pull)) };
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
  return { ...facts, board: { items: [...(facts.board?.items ?? []), { ...template, id: 'gh#14', title: 'Fourteen', priority: '', needs: ['priority'], url: 'https://example/14', parent: 'gh#7', ...change }], bodies: facts.board?.bodies ?? {}, spend: facts.board?.spend ?? {}, trackerErrors: [] } };
};
/** Adds board items made from gh#12's shape, one per change. */
const withBoardItems = (facts: ReconcileInput, changes: Partial<BoardItem>[]): ReconcileInput => {
  const template = (facts.board?.items ?? []).find((item) => item.id === 'gh#12')!;
  return { ...facts, board: { items: [...(facts.board?.items ?? []), ...changes.map((change) => ({ ...template, ...change }))], bodies: facts.board?.bodies ?? {}, spend: facts.board?.spend ?? {}, trackerErrors: [] } };
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

test('Worktree_ItemNotOnBoard_IssueLinkedWithNoTitle', async () => {
  const stale = worktree(await snapshot(), 'project-wt-4');
  assert.deepEqual([stale?.itemUrl, stale?.itemTitle], ['https://github.com/example/fixture/issues/5', null], 'because the issue page follows from the id and github.repo, while the title is known only from the board');
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
  const blocking = { ...facts, board: { items: (facts.board?.items ?? []).map((item) => (item.id === 'gh#9' ? { ...item, blocked_by: ['gh#14'] } : item)), bodies: {}, spend: {}, trackerErrors: [] } };
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
  assert.deepEqual((await snapshot()).readiness, { ready: 1, waitingOnField: 0, blocked: 1, held: 0, gated: 2, nextInLineMissingField: 0 }, 'because gh#12 is ready, gh#13 is blocked, gh#7 waits at a gate, gh#20 ran every step and waits on its owner, and the running and stale items are in none');
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

test('PullState_ReviewStillRequested_ReviewPending', () => {
  assert.equal(pullState(ready({ reviewDecision: null, reviewsRequested: 1 })), 'review-pending', 'because a reviewer asked and not yet answered is a review in progress, not a pull ready to merge');
});

/** gh#20 at the merge gate: done, naming the open pull #20, with the pull and the health job's review records changed as given. */
const mergeGateOn20 = async (pull: Partial<PullFact>, reviews: ReconcileInput['flow']['reviews'] = []): Promise<ReconcileInput> => {
  const facts = withBoardItem(await input(), 'gh#20', { gate: 'merge' });
  facts.flow = { ...facts.flow, reviews, gates: [{ item: 'gh#20', gate: 'merge', message: 'Merge #20', time: '2026-10-24T10:00:00Z', host: 'shell', questions: null, plan: null }] };
  facts.pulls = { merged: [], pulls: (facts.pulls?.pulls ?? []).map((entry) => (entry.number === 20 ? { ...entry, ...pull } : entry)) };
  return facts;
};
const shownAtMergeGate = (picture: Snapshot): boolean[] => [
  picture.gates.some((gate) => gate.item === 'gh#20'),
  picture.items.find((item) => item.id === 'gh#20')?.state === 'needs-you',
  picture.attention.some((row) => row.kind === 'gate' && row.id === 'gh#20'),
];

test('MergeGate_PullReadyAndReviewed_ShownAtTheGate', async () => {
  const picture = reconcile(await mergeGateOn20({}, [{ pr: 20, state: 'ready', waiting: [], cannot: [], at: '2026-10-24T18:00:00Z' }]));
  assert.deepEqual(shownAtMergeGate(picture), [true, true, true], 'because only the merge is left, which is the owner\'s');
  assert.equal(picture.counts.needsYou, 1, 'because the gate counts as needing you');
});

test('MergeGate_ChangesRequested_NotShownAtTheGate', async () => {
  const picture = reconcile(await mergeGateOn20({ reviewDecision: 'CHANGES_REQUESTED' }));
  assert.deepEqual(shownAtMergeGate(picture), [false, false, false], 'because a reviewer asked for changes, so the comments job works on the PR before anyone merges it');
  assert.equal(picture.counts.needsYou, 0, 'because nothing waits on you yet');
  assert.equal(pullNumbered(picture, 20)?.state, 'changes-requested', 'because the pull itself says where the review stands');
});

test('MergeGate_ReviewStillRequested_NotShownAtTheGate', async () => {
  const picture = reconcile(await mergeGateOn20({ reviewDecision: null, reviewsRequested: 1 }));
  assert.deepEqual(shownAtMergeGate(picture), [false, false, false], 'because a requested reviewer has not reviewed yet');
});

test('MergeGate_FlowReviewerYetToAnswer_NotShownAtTheGate', async () => {
  const picture = reconcile(await mergeGateOn20({}, [{ pr: 20, state: 'in-review', waiting: ['codex'], cannot: [], at: '2026-10-24T18:00:00Z' }]));
  assert.deepEqual(shownAtMergeGate(picture), [false, false, false], 'because codex, asked by a mention GitHub does not track, has not answered, as the health job recorded');
});

test('MergeGate_FlowReviewerYetToAnswer_ItemAndPullInReview', async () => {
  const picture = reconcile(await mergeGateOn20({}, [{ pr: 20, state: 'in-review', waiting: ['codex'], cannot: [], at: '2026-10-24T18:00:00Z' }]));
  const pull = picture.pulls.find((entry) => entry.number === 20);
  assert.equal(picture.items.find((item) => item.id === 'gh#20')?.state, 'in-review', 'because the item waits on its reviewers, which is neither the owner\'s gate nor a blocker');
  assert.deepEqual([pull?.state, pull?.review?.waiting], ['in-review', ['codex']], 'because GitHub calls the pull mergeable, but codex was asked by a mention and has not answered');
  assert.equal(picture.attention.some((row) => row.kind === 'pr-mergeable' && row.id === 'gh#20'), false, 'because a pull in review is not ready to merge yet');
});

test('PullReview_ReviewerCannot_ReplyCarried', async () => {
  const cannot = [{ reviewer: 'codex', said: 'Create an environment for this repo.' }];
  const picture = reconcile(await mergeGateOn20({}, [{ pr: 20, state: 'ready', waiting: [], cannot, at: '2026-10-24T18:00:00Z' }]));
  const pull = picture.pulls.find((entry) => entry.number === 20);
  assert.deepEqual([pull?.state, pull?.review?.cannot], ['mergeable', cannot], 'because the reply shows on the pull until the record goes, while the pull itself is ready');
});

test('PullReview_NoRecord_Null', async () => {
  assert.equal((await snapshot()).pulls.find((entry) => entry.number === 21)?.review, null, 'because the health job wrote no record for #21');
});

test('MergeGate_StaleRecordChangesRequestedPullApproved_ShownAtTheGate', async () => {
  const picture = reconcile(await mergeGateOn20({}, [{ pr: 20, state: 'changes-requested', waiting: [], cannot: [], at: '2026-10-24T18:00:00Z' }]));
  assert.deepEqual(shownAtMergeGate(picture), [true, true, true], 'because the live pull says the reviewer approved since, and the health job\'s record is up to 15 minutes old');
});

test('MergeGate_RecordWaitingOnCopilotOnlyNoLiveRequest_ShownAtTheGate', async () => {
  const picture = reconcile(await mergeGateOn20({}, [{ pr: 20, state: 'in-review', waiting: ['copilot'], cannot: [], at: '2026-10-24T18:00:00Z' }]));
  assert.deepEqual(shownAtMergeGate(picture), [true, true, true], 'because Copilot is asked through GitHub, whose live pull shows no request left, so the record is stale');
});

test('MergeGate_PullsUnreadRecordChangesRequested_NotShownAtTheGate', async () => {
  const facts = await mergeGateOn20({}, [{ pr: 20, state: 'changes-requested', waiting: [], cannot: [], at: '2026-10-24T18:00:00Z' }]);
  facts.pulls = null;
  assert.deepEqual(shownAtMergeGate(reconcile(facts)), [false, false, false], 'because without the live pull the health job\'s verdict is the best there is');
});

test('MergeGate_RequiredApprovalOnly_ShownAtTheGate', async () => {
  const picture = reconcile(await mergeGateOn20({ reviewDecision: 'REVIEW_REQUIRED', mergeState: 'BLOCKED' }));
  assert.deepEqual(shownAtMergeGate(picture), [true, true, true], 'because at the merge gate the approval the repository requires is the owner\'s to give');
});

test('MergeGate_RecordForAnotherPull_ShownAtTheGate', async () => {
  const picture = reconcile(await mergeGateOn20({}, [{ pr: 21, state: 'in-review', waiting: ['codex'], cannot: [], at: '2026-10-24T18:00:00Z' }]));
  assert.deepEqual(shownAtMergeGate(picture), [true, true, true], 'because the record is about another pull');
});

test('MergeGate_PullsUnreadRecordInReview_NotShownAtTheGate', async () => {
  const facts = await mergeGateOn20({}, [{ pr: 20, state: 'in-review', waiting: ['claude'], cannot: [], at: '2026-10-24T18:00:00Z' }]);
  facts.pulls = null;
  assert.deepEqual(shownAtMergeGate(reconcile(facts)), [false, false, false], 'because without pull requests the item still names #20, and the health job says it is in review');
});

test('OtherGate_PullInReview_StillShown', async () => {
  const facts = await mergeGateOn20({ reviewDecision: 'CHANGES_REQUESTED' });
  facts.flow.gates = facts.flow.gates.map((gate) => ({ ...gate, gate: 'escalation' }));
  assert.equal(reconcile(facts).gates.length, 1, 'because only the merge gate waits on the review; every other gate is the owner\'s question');
});

/** gh#7, claimed in project-wt-2, at the merge gate and naming the pull given. */
const mergeGateOn7 = async (pr: string): Promise<ReconcileInput> => {
  const facts = withBoardItem(await input(), 'gh#7', { gate: 'merge', pr });
  facts.flow = { ...facts.flow, gates: [{ item: 'gh#7', gate: 'merge', message: 'Merge it', time: '2026-10-24T10:00:00Z', host: 'shell', questions: null, plan: null }] };
  return facts;
};

test('LandedMergeGates_NamedPullNotOpen_Listed', async () => {
  assert.deepEqual(landedMergeGates(await mergeGateOn7('https://github.com/example/fixture/pull/30')), [{ item: 'gh#7', raisedAt: '2026-10-24T10:00:00Z' }], 'because #30 left the open list, so it was merged or closed and only a sweep clears its gate');
});

test('LandedMergeGates_NamedPullStillOpen_NotListed', async () => {
  assert.deepEqual(landedMergeGates(await mergeGateOn7('#560')), [], 'because #560 is open, so the owner has not merged it yet');
});

test('LandedMergeGates_NoPullNamed_NotListed', async () => {
  assert.deepEqual(landedMergeGates(await mergeGateOn7('')), [], 'because without a named pull nothing says a merge happened');
});

test('LandedMergeGates_PullsOrBoardUnread_NotListed', async () => {
  const facts = await mergeGateOn7('#30');
  assert.deepEqual([landedMergeGates({ ...facts, pulls: null }), landedMergeGates({ ...facts, board: null })], [[], []], 'because a list not read proves nothing about the pull');
});

test('LandedMergeGates_NoClaim_NotListed', async () => {
  const facts = await mergeGateOn7('#30');
  facts.flow = { ...facts.flow, claims: facts.flow.claims.filter((claim) => claim.item !== 'gh#7') };
  assert.deepEqual(landedMergeGates(facts), [], 'because a sweep only frees claimed worktrees, so it would read the pull for nothing');
});

test('LandedMergeGates_OtherGate_NotListed', async () => {
  const facts = await mergeGateOn7('#30');
  facts.flow.gates = facts.flow.gates.map((gate) => ({ ...gate, gate: 'escalation' }));
  assert.deepEqual(landedMergeGates(facts), [], 'because a merge answers only the merge gate');
});

test('Project_GithubAdapter_RepoAndIssuesUrls', async () => {
  const { project } = await snapshot();
  assert.deepEqual([project.repoUrl, project.trackers.find((tracker) => tracker.name === 'github')?.url, project.jobsHost], ['https://github.com/example/fixture', 'https://github.com/example/fixture/issues', 'claude'], 'because the header links the repository and the tracker and says which CLI the jobs run');
});

test('Project_TrackersWithoutGithub_NoTrackerUrl', async () => {
  const facts = await input();
  facts.flow.config.trackers = ['local'];
  assert.deepEqual(reconcile(facts).project.trackers.map((tracker) => tracker.url), [null], 'because the local tracker has no page to open');
});

test('Project_TrackersReadGithubBesideALocalDefault_IssuesUrl', async () => {
  const facts = await input();
  facts.flow.config.adapter = 'local';
  facts.flow.config.trackers = ['github', 'local'];
  assert.deepEqual(reconcile(facts).project.trackers.map((tracker) => tracker.url), ['https://github.com/example/fixture/issues', null], 'because the flow reads GitHub issues even while new items default to local');
});

/** The fixture project reading Jira beside GitHub, on the site and project given. */
async function jiraInput(site = 'https://acme.atlassian.net/'): Promise<ReconcileInput> {
  const facts = await input();
  facts.flow.config.trackers = ['github', 'jira'];
  facts.flow.config.jiraSite = site;
  facts.flow.config.jiraProject = 'WID';
  return facts;
}

test('Project_JiraTracker_ListedWithItsProjectPage', async () => {
  const { project } = reconcile(await jiraInput());
  assert.deepEqual(project.trackers, [
    { name: 'github', url: 'https://github.com/example/fixture/issues', error: null },
    { name: 'jira', url: 'https://acme.atlassian.net/browse/WID', error: null },
  ], 'because the header names every tracker the flow reads, each linked to its items, in the order of trackers');
});

test('Project_LocalTracker_ListedWithNoPage', async () => {
  const facts = await input();
  facts.flow.config.trackers = ['local'];
  assert.deepEqual(reconcile(facts).project.trackers, [{ name: 'local', url: null, error: null }], 'because the local tracker keeps its items in files, with no page to open');
});

test('Project_JiraSiteNotHttps_NoPage', async () => {
  const project = reconcile(await jiraInput('http://acme.atlassian.net')).project;
  assert.equal(project.trackers.find((tracker) => tracker.name === 'jira')?.url, null, 'because the adapter refuses a site that is not https, so the console links none');
});

test('Project_TrackerTheBoardCouldNotRead_CarriesTheError', async () => {
  const facts = await jiraInput();
  facts.board = { ...facts.board!, trackerErrors: [{ tracker: 'jira', code: 1, message: 'flow: jira.site is not set' }] };
  assert.deepEqual(reconcile(facts).project.trackers.map((tracker) => tracker.error), [null, 'flow: jira.site is not set'], 'because the header says which tracker failed and why, so the missing items are not taken for none');
});

test('Worktree_JiraItemNotOnBoard_LinksTheIssueOnTheSite', async () => {
  const facts = await jiraInput();
  facts.flow.claims = facts.flow.claims.map((claim) => (claim.item === 'gh#5' ? { ...claim, item: 'jira:WID-5' } : claim));
  assert.equal(worktree(reconcile(facts), 'project-wt-4')?.itemUrl, 'https://acme.atlassian.net/browse/WID-5', 'because a Jira issue opens at <site>/browse/<key>, the link the worktree keeps while the board cannot list it');
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
  facts.processes = NOTHING_RUNS;
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
  const recordOnly = { ...live, processes: NOTHING_RUNS };
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
  facts.processes = NOTHING_RUNS;
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
  const picture = reconcile({ ...facts, board: { items: facts.board?.items ?? [], bodies: { 'gh#7': '## Spec' }, spend: {}, trackerErrors: [] } });
  assert.equal(picture.gates.find((gate) => gate.item === 'gh#7')?.body, '## Spec', 'because the card shows the issue the gate is about');
});

test('BoardJson_KeepsBodiesApartFromItems', () => {
  const board = parseBoard(JSON.stringify({ items: [{ id: 'gh#1', status: 'open', blocked_by: [], body: 'text' }] }));
  assert.deepEqual([board.bodies, 'body' in board.items[0]!], [{ 'gh#1': 'text' }, false], 'because only gates carry a body, not every item on every snapshot');
});


/** The input with the run log and the status rows' changes given. */
async function withJobs(runs: JobRunRecord[], change: (rows: JobStatusRow[]) => void = () => {}): Promise<ReconcileInput> {
  const facts = await input();
  const rows = parseJobStatus(JOBS_JSON);
  change(rows);
  return { ...facts, jobs: { jobs: rows, runs } };
}

const jobOf = (picture: Snapshot, name: string) => picture.jobs.find((job) => job.name === name);
const run = (job: string, at: string, result: string, extra: Partial<JobRunRecord> = {}): JobRunRecord => ({ job, host: 'claude', at, seconds: 3, exit: 0, result, ...extra });

test('JobRecent_FromTheRunLog_NewestFirstWithItsWorkersAndSkips', async () => {
  const runs = [
    run('next', '2026-10-24T17:00:00Z', 'done, 2 steps'),
    run('health', '2026-10-24T17:05:00Z', 'quiet: nothing to do'),
    run('next-2', '2026-10-24T17:30:00Z', 'skipped: run 36596 still going', { host: 'codex' }),
    run('next-1', '2026-10-24T17:44:00Z', 'quiet: nothing ready', { host: '' }),
  ];
  const recent = jobOf(reconcile(await withJobs(runs)), 'next')?.recent ?? [];
  assert.deepEqual(recent.map((entry) => [entry.at, entry.worker, entry.host, entry.outcome, entry.reason]), [
    ['2026-10-24T17:44:00Z', 'next-1', null, 'quiet', 'nothing ready'],
    ['2026-10-24T17:30:00Z', 'next-2', 'codex', 'skipped', 'run 36596 still going'],
    ['2026-10-24T17:00:00Z', null, 'claude', 'work', 'done, 2 steps'],
  ], "because next's workers are next-N, a skip is a run the owner wants to see, and the health line is the health job's");
});

test('JobRecent_LongLog_KeepsTheNewestJobRunsKept', async () => {
  const runs = Array.from({ length: JOB_RUNS_KEPT + 5 }, (_, index) => run('health', `2026-10-24T${String(index).padStart(2, '0')}:00:00Z`, 'quiet: nothing to do'));
  const recent = jobOf(reconcile(await withJobs(runs)), 'health')?.recent ?? [];
  assert.equal(recent.length, JOB_RUNS_KEPT, 'because the card shows a dozen runs, not the whole log');
  assert.equal(recent[0]?.at, runs.at(-1)?.at, 'because the newest run comes first');
});

test('JobRecent_JobWithASimilarName_NotMixedIn', async () => {
  const runs = [run('next', '2026-10-24T17:00:00Z', 'quiet: nothing ready'), run('nextish', '2026-10-24T17:01:00Z', 'done'), run('next-x', '2026-10-24T17:02:00Z', 'done')];
  assert.deepEqual(jobOf(reconcile(await withJobs(runs)), 'next')?.recent.map((entry) => entry.at), ['2026-10-24T17:00:00Z'], 'because only next and next-<number> are the next job, as flow\'s own runs reader matches them');
});

test('JobRun_FlowsOwnOutcomeAndReason_Win', async () => {
  const runs = [run('retro', '2026-10-24T17:00:00Z', 'skipped: run 1 still going', { outcome: 'quiet', reason: 'flow said so' })];
  const recent = jobOf(reconcile(await withJobs(runs)), 'retro')?.recent[0];
  assert.deepEqual([recent?.outcome, recent?.reason], ['quiet', 'flow said so'], 'because flow classifies its own runs, and the console only fills in for a line without them');
});

test('JobLast_FromStatus_CarriesReasonWorkerAndHost', async () => {
  const facts = await withJobs([], (rows) => { rows[0]!.last = { job: 'next-2', host: 'codex', at: '2026-10-24T17:44:00Z', seconds: 107, exit: 0, result: 'quiet: nothing ready', outcome: 'quiet' }; });
  const last = jobOf(reconcile(facts), 'next')?.last;
  assert.deepEqual([last?.reason, last?.worker, last?.host], ['nothing ready', 'next-2', 'codex'], 'because the card says why the last run did nothing, and which worker on which host ran it');
});

test('JobLast_OlderFlowWithoutJobOrHost_NullWorkerAndHost', async () => {
  const last = jobOf(await snapshot(), 'health')?.last;
  assert.deepEqual([last?.worker, last?.host, last?.reason, last?.outcome], [null, null, 'git failed', 'failed'], 'because a status row with no job or host names neither, and its result is its reason');
});

test('JobWorkers_FromStatus_MappedWithTheirRunAndLastRun', async () => {
  const facts = await withJobs([], (rows) => {
    rows[0]!.workers = [
      { job: 'next-1', host: 'claude', running: { job: 'next-1', pid: 36596, at: '2026-10-24T18:00:00Z', host: 'claude' }, last_run: null },
      { job: 'next-2', host: 'codex', running: null, last_run: { job: 'next-2', host: 'codex', at: '2026-10-24T17:30:00Z', seconds: 0, exit: 0, result: 'skipped: run 36597 still going', outcome: 'skipped', reason: 'run 36597 still going' } },
    ];
  });
  const workers = jobOf(reconcile(facts), 'next')?.workers;
  assert.deepEqual(workers?.map((worker) => [worker.name, worker.host, worker.running, worker.last?.reason ?? null, worker.last?.worker ?? null]), [
    ['next-1', 'claude', { pid: 36596, since: '2026-10-24T18:00:00Z' }, null, null],
    ['next-2', 'codex', null, 'run 36597 still going', 'next-2'],
  ], 'because each worker shows what runs on it now and why its last run ended');
});

test('JobWorkers_OtherJobOrOlderFlow_Empty', async () => {
  const picture = await snapshot();
  assert.deepEqual(picture.jobs.map((job) => job.workers), [[], [], []], 'because jobs.sh before 1.24.0 lists no workers, and only next has any');
});

test('NamedSchedule_JobHostAndConfigured_CarriedWithItsOwnRunsAndWorkers', async () => {
  const runs = [run('next', '2026-10-24T17:00:00Z', 'done, 2 steps'), run('next-nightly-2', '2026-10-24T17:10:00Z', 'quiet: nothing ready'), run('next-nightly', '2026-10-24T17:20:00Z', 'done, 1 step')];
  const facts = await withJobs(runs, (rows) => {
    rows.push({ ...rows[0]!, name: 'next-nightly', job: 'next', host: 'codex', configured: false, workers: [] });
  });
  const picture = reconcile(facts);
  const nightly = jobOf(picture, 'next-nightly');
  assert.deepEqual([nightly?.job, nightly?.host, nightly?.configured], ['next', 'codex', false], 'because the card says which job the schedule runs, on which host, and that the config no longer names it');
  assert.deepEqual(nightly?.recent.map((entry) => [entry.at, entry.worker]), [['2026-10-24T17:20:00Z', null], ['2026-10-24T17:10:00Z', 'next-nightly-2']], 'because a named schedule\'s runs are its own and its workers\', <name>-<n>');
  assert.deepEqual(jobOf(picture, 'next')?.recent.map((entry) => entry.at), ['2026-10-24T17:00:00Z'], 'because next-nightly-2 is a worker of next-nightly, not of next');
  assert.deepEqual([jobOf(picture, 'health')?.job, jobOf(picture, 'health')?.configured], ['health', true], 'because a row from an older plugin is the job of its own name, in the config');
});

test('RunOutcome_ClassifiedAsFlowsJobsPyDoes', () => {
  const cases: [string, number | string | null, string][] = [
    ['paused: resume it with the flow jobs skill', 0, 'paused'], ['skipped: run 1 still going', 0, 'skipped'], ['done, 2 steps', 1, 'failed'],
    ['error: jobs.workers names gemini', 2, 'failed'], ['stopped: no step ran (exit 0: x)', 0, 'failed'], ['quiet: nothing ready', 0, 'quiet'],
    ['stopped at a gate (see .flow/gates)', 0, 'gate'], ['done, 3 steps', 0, 'work'], ['done', '0', 'work'],
  ];
  for (const [result, exit, outcome] of cases) assert.equal(runOutcome(result, exit), outcome, `because flow calls "${result}" with exit ${String(exit)} ${outcome}`);
});

test('RunReason_TheResultWithoutItsOutcomeWord', () => {
  const cases: [string, string | null][] = [
    ['skipped: run 36596 still going', 'run 36596 still going'], ['paused: resume it with the flow jobs skill', 'the job is paused'],
    ['stopped: exit 3', 'exit 3'], ['done, 2 steps', 'done, 2 steps'], ['quiet:', null], ['', null],
  ];
  for (const [result, reason] of cases) assert.equal(runReason(result), reason, `because flow's reason for "${result}" is ${String(reason)}`);
});

test('StoppedHost_InTheSnapshotAndOnTheNeedsYouListWithItsClear', async () => {
  const facts = await input();
  facts.flow.stoppedHosts = [{ host: 'claude', cause: 'spend-limit', said: 'You have hit your limit', at: '2026-10-24T18:00:00Z', item: null }];
  const picture = reconcile(facts);
  assert.deepEqual(picture.stoppedHosts.map((stopped) => stopped.host), ['claude'], 'because the Jobs screen shows which host starts no session');
  const row = picture.attention.find((entry) => entry.kind === 'host-stopped');
  assert.deepEqual([row?.id, row?.title, row?.ageSeconds], ['claude', 'claude is stopped on a spend limit', 964], 'because the row names the host and the cause in words, aged from the stop');
  assert.match(row?.detail ?? '', /^claude stopped on a spend limit: You have hit your limit\. No claude session starts until you clear it\.$/, 'because the owner reads what the host said and what clearing does');
  assert.deepEqual(row?.action, { kind: 'host.clear', args: { host: 'claude' }, label: 'Clear claude' }, 'because the row clears the host with gate.sh clear claude');
});

test('StoppedHostOnAuthForAGate_CauseInWordsAndTheGateNamed', async () => {
  const facts = await input();
  facts.flow.stoppedHosts = [{ host: 'codex', cause: 'auth', said: 'Not logged in', at: null, item: 'gh#7' }];
  const row = reconcile(facts).attention.find((entry) => entry.kind === 'host-stopped');
  assert.equal(row?.detail, 'codex stopped on an auth error: Not logged in. No codex session starts until you clear it, or when the gate on gh#7 clears.', 'because clearing the gate that names the stop starts the host again too');
});

test('NoStoppedHost_NoRowAndOtherRowsHaveNoAction', async () => {
  const picture = await snapshot();
  assert.deepEqual([picture.stoppedHosts, picture.attention.filter((row) => row.action !== null)], [[], []], 'because only a stopped host has a button on its row');
});

test('JobHosts_SchedulesAndWorkers_DistinctAndSorted', async () => {
  const facts = await withJobs([], (rows) => {
    rows[0]!.host = 'claude';
    rows[0]!.workers = [
      { job: 'next-1', host: 'codex', running: null, last_run: null },
      { job: 'next-2', host: 'claude', running: null, last_run: null },
    ];
    rows.push({ ...rows[0]!, name: 'next-nightly', job: 'next', host: 'codex', workers: [] });
  });
  assert.deepEqual(reconcile(facts).project.jobHosts, ['claude', 'codex'], 'because the header names each host a schedule or a worker runs on, once each');
});

test('Project_StaleSessionLimit_FromTheConfig', async () => {
  const facts = await input();
  facts.flow.config.staleSessionSeconds = 7200;
  assert.equal(reconcile(facts).project.staleSessionSeconds, 7200, 'because the page calls a session stale by jobs.health.stale_session, as the health job does');
});

test('JobHosts_NoJobSaysAHost_JobsHostAlone', async () => {
  const facts = await input();
  facts.flow.config.jobsHost = 'codex';
  assert.deepEqual(reconcile(facts).project.jobHosts, ['codex'], 'because with no host in jobs.sh status the jobs run on jobs.host');
});

test('ProjectPlugins_FromTheInput_LeftOutNone', async () => {
  const facts = await input();
  const plugins = [{ name: 'flow', marketplace: 'brain-plugins', claude: '1.27.1', codex: null }];
  assert.deepEqual([reconcile({ ...facts, plugins }).project.plugins, reconcile(facts).project.plugins], [plugins, []], 'because the snapshot carries what the files read found, and nothing when it was not read');
});

test('ProjectPicks_FromTheConfig', async () => {
  const facts = await input();
  const mine = { name: 'mine', assignee: 'me', status: [], labels: [], kinds: [], trackers: [], query: '' };
  facts.flow.config.picks = [mine];
  assert.deepEqual(reconcile(facts).project.picks, [mine], 'because the Jobs page offers the filters the config names');
});

test('Snapshot_Lessons_EveryLessonOfTheFlowHome', async () => {
  assert.deepEqual((await snapshot()).lessons.map((lesson) => lesson.rule), ['T-09', null, 'T-09', 'N-05'], 'because the Retro page groups every lesson by kind then rule');
});

test('Snapshot_Retros_NewestFirstWithTheReportNoLineNames', async () => {
  assert.deepEqual((await snapshot()).retros.map((run) => run.date), ['2026-10-19', '2026-10-15', '2026-10-08'], 'because each retro shows, latest first, and a report without its log line too');
});

test('Counts_LessonsSinceRetro_ThoseAfterTheLastRetrosCount', async () => {
  assert.equal((await snapshot()).counts.lessonsSinceRetro, 2, 'because the last retro read three lines, the cut-short one among them, so the lessons on lines four and five are new');
});

test('MergedToday_LinkedByTaskBranch', async () => {
  const merged = (await snapshot()).mergedToday;
  assert.deepEqual(merged.map((pull) => [pull.number, pull.item]), [[19, 'gh#9'], [18, null]], 'because a merged pull carries the item whose task branch was its head, and none for a branch no item names');
});

test('MergedToday_ClosedItem_NamedByItsTaskBranch', async () => {
  const facts = await input();
  facts.pulls = { pulls: facts.pulls?.pulls ?? [], merged: [
    { number: 40, title: 'Forty', url: 'https://github.com/example/fixture/pull/40', branch: 'flow/gh-140', createdAt: '2026-10-24T09:00:00Z', mergedAt: '2026-10-24T17:00:00Z' },
    { number: 41, title: 'Forty-one', url: 'https://github.com/example/fixture/pull/41', branch: 'flow/local-task-3', createdAt: '2026-10-24T09:00:00Z', mergedAt: '2026-10-24T16:00:00Z' },
  ] };
  assert.deepEqual(reconcile(facts).mergedToday.map((pull) => pull.item), ['gh#140', 'local:task/3'], 'because a merged item is often closed and off the board, and its task branch still names it');
});

test('MergedToday_PullsNotRead_Empty', async () => {
  const facts = await input();
  facts.pulls = null;
  assert.deepEqual(reconcile(facts).mergedToday, [], 'because nothing merged is known before the pulls are read');
});

test('Pull_ReviewHoldFacts_CarriedForTheCard', async () => {
  const facts = await input();
  facts.pulls = { pulls: [ready({ reviewDecision: null, changesRequested: 1, reviewsRequested: 2, checks: { passed: 2, failed: 1, pending: 0 } })], merged: [] };
  const pull = pullNumbered(reconcile(facts), 30);
  assert.deepEqual([pull?.state, pull?.changesRequested, pull?.reviewsRequested], ['checks-failing', 1, 2], 'because the card keeps Merge when green off for a review hold a failing check hides from the state');
});

/** A Codex app server working at `cwd`, as the process read finds one. */
const appServer = (pid: number, cwd: string): ProcessFacts['servers'][number] => ({
  pid, host: 'codex', label: 'Codex app server', cwd, elapsedSeconds: 183600, startedAt: '2026-10-22T15:16:04.000Z', command: '/x/codex app-server --listen unix:///tmp/codex.sock',
});

test('Servers_InAPoolWorktree_ListedWithIt', async () => {
  const facts = await input();
  facts.processes = { ...NOTHING_RUNS, servers: [appServer(64347, path.resolve(FIXTURE_ROOT, '../project-wt-3/src'))] };
  assert.deepEqual(reconcile(facts).servers.map((server) => [server.pid, server.label, server.worktree]), [[64347, 'Codex app server', 'project-wt-3']], 'because a server working in the pool is part of what runs for this project');
});

test('Servers_InTheMainWorktree_Listed', async () => {
  const facts = await input();
  facts.processes = { ...NOTHING_RUNS, servers: [appServer(56354, FIXTURE_ROOT)] };
  assert.deepEqual(reconcile(facts).servers.map((server) => server.worktree), [path.basename(FIXTURE_ROOT)], 'because the main worktree is the project too');
});

test('Servers_OutsideTheProject_LeftOut', async () => {
  const facts = await input();
  facts.processes = { ...NOTHING_RUNS, servers: [appServer(701, '/Users/x'), appServer(702, path.resolve(FIXTURE_ROOT, '../project-wt-30'))] };
  assert.deepEqual(reconcile(facts).servers, [], 'because the Codex app bundle\'s servers in the home folder, or in a folder that only shares a name prefix, are another project\'s or nobody\'s');
});

test('Servers_NeverAgentsOrSessions', async () => {
  const facts = await input();
  facts.processes = { ...NOTHING_RUNS, servers: [appServer(64347, path.resolve(FIXTURE_ROOT, '../project-wt-3'))] };
  const picture = reconcile(facts);
  assert.deepEqual([picture.agents, worktree(picture, 'project-wt-3')?.sessions, worktree(picture, 'project-wt-3')?.flags.includes('session')], [[], [], false], 'because the comments and health jobs pass a server by, and the page must not show it as someone at work');
});
