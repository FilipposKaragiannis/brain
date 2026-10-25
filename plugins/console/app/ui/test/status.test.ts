import { expect, test } from 'vitest';
import type { Job } from '../../daemon/src/snapshot.ts';
import { actionTone, attentionTone, countTone, freshnessTone, itemTone, jobTone, worktreeTone } from '../src/status.ts';

const IDLE_JOB: Job = {
  name: 'next', state: 'scheduled', schedule: 'every 30m', args: '', installed: true, loaded: true, paused: false, running: [],
  last: { at: '2026-10-24T18:00:00Z', seconds: 42, exit: 0, result: 'quiet', outcome: 'idle' }, next: '18:30', runsThisWeek: 3, failedThisWeek: 0,
};

test('RunningWorktree_IsGreen', () => {
  expect(worktreeTone('running'), 'because green pulse means an agent is working there').toBe('running');
});

test('GatedWorktree_NeedsYou', () => {
  expect(worktreeTone('needs-you'), 'because orange means a gate waits on a person').toBe('needs-you');
});

test('StaleWorktree_IsHatchedPurple', () => {
  expect(worktreeTone('stale'), 'because stale has its own tone, apart from failing').toBe('stale');
});

test('ClaimedAndFreeWorktrees_AreBothGrey', () => {
  expect([worktreeTone('claimed'), worktreeTone('free')], 'because nothing waits on a claimed idle worktree or a free one').toEqual(['quiet', 'quiet']);
});

test('ItemAtAGate_NeedsYou', () => {
  expect(itemTone('needs-you'), 'because items and worktrees share one status language').toBe('needs-you');
});

test('DeadRunAttention_IsFailing', () => {
  expect(attentionTone('dead-run'), 'because a run record with no process is broken, not waiting').toBe('failing');
});

test('GateAttention_NeedsYou', () => {
  expect(attentionTone('gate'), 'because a gate row is the person\'s to answer').toBe('needs-you');
});

test('JobWhoseLastRunExitedNonZero_IsFailing', () => {
  const failed: Job = { ...IDLE_JOB, last: { at: '2026-10-24T18:00:00Z', seconds: 3, exit: 2, result: 'boom', outcome: 'error' } };
  expect(jobTone(failed), 'because a non-zero exit is a failure even while the job sits scheduled').toBe('failing');
});

test('ScheduledJobWithCleanLastRun_IsGrey', () => {
  expect(jobTone(IDLE_JOB), 'because a job waiting for its slot needs nothing').toBe('quiet');
});

test('RunningJob_IsGreen', () => {
  expect(jobTone({ ...IDLE_JOB, state: 'running', running: ['next'] }), 'because a running job is live work').toBe('running');
});

test('RejectedAction_IsFailing', () => {
  expect(actionTone('rejected'), 'because a refused action did not do what the button asked').toBe('failing');
});

test('SourceThatFailedToRead_IsFailing', () => {
  expect(freshnessTone({ at: null, ageSeconds: null, ok: false, error: 'gh: not logged in' }), 'because a source error is shown red').toBe('failing');
});

test('ZeroCount_TileIsGrey', () => {
  expect(countTone(0, 'needs-you'), 'because an empty tile should not draw the eye').toBe('quiet');
});
