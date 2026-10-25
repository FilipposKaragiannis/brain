import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseBoard } from '../src/collectors/board.ts';
import { readFlowHome } from '../src/collectors/flowHome.ts';
import { readGit } from '../src/collectors/git.ts';
import { parseJobStatus } from '../src/collectors/jobs.ts';
import { readProcesses } from '../src/collectors/processes.ts';
import { reconcile } from '../src/reconcile.ts';
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
    sources: { files: fresh, git: fresh, processes: fresh, jobs: fresh, board: fresh },
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
