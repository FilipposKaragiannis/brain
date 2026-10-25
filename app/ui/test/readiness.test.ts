import { expect, test } from 'vitest';
import { readinessSentence } from '../src/readiness.ts';
import { poolWorktree, snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

const COUNTS = snapshotAt(TAKEN_AT, 0).counts;

test('NothingRuns_SaysWhatEachBucketWaitsOn', () => {
  const sentence = readinessSentence({ ready: 0, waitingOnField: 4, gated: 5, blocked: 12 }, COUNTS, []);
  expect(sentence, 'because the owner reads in one line why no agent works').toBe('Nothing runs: 4 items wait on a field, 5 wait at gates, 12 are blocked.');
});

test('OneItemInABucket_SpeaksInTheSingular', () => {
  const sentence = readinessSentence({ ready: 1, waitingOnField: 0, gated: 1, blocked: 0 }, COUNTS, []);
  expect(sentence, 'because "1 items wait" reads as a bug').toBe('Nothing runs: 1 item is ready for the next job, 1 waits at a gate.');
});

test('AWorktreeRuns_NamesItsItem', () => {
  const running = { ...poolWorktree('wt-3'), state: 'running' as const, item: 'gh#41' };
  const sentence = readinessSentence({ ready: 0, waitingOnField: 0, gated: 0, blocked: 2 }, COUNTS, [running]);
  expect(sentence, 'because when something runs the line says what').toBe('gh#41 runs now; 2 items are blocked.');
});

test('AJobRunsWithNoWorktree_SaysAJobRuns', () => {
  const sentence = readinessSentence({ ready: 0, waitingOnField: 0, gated: 0, blocked: 0 }, { ...COUNTS, jobsRunning: 1 }, []);
  expect(sentence, 'because a job that runs is work going on even before it claims a worktree').toBe('1 job runs.');
});

test('NoOpenWork_SaysNothingWaits', () => {
  expect(readinessSentence({ ready: 0, waitingOnField: 0, gated: 0, blocked: 0 }, COUNTS, []), 'because an empty board must not read like a stall').toBe('Nothing runs, and no open item waits.');
});
