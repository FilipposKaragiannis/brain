import { expect, test } from 'vitest';
import { readinessSentence } from '../src/readiness.ts';
import { poolWorktree, readiness, snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

const COUNTS = snapshotAt(TAKEN_AT, 0).counts;

test('NothingRuns_SaysWhatEachBucketWaitsOn', () => {
  const sentence = readinessSentence(readiness({ waitingOnField: 168, nextInLineMissingField: 4, gated: 4, blocked: 26 }), COUNTS, []);
  expect(sentence, 'because the owner reads in one line why no agent works').toBe('Nothing runs: 4 items that are next in line lack a field, 164 more in the backlog lack one, 4 wait at gates, 26 are blocked.');
});

test('NoneNextInLine_SaysTheBacklogLacksAField', () => {
  const sentence = readinessSentence(readiness({ waitingOnField: 12 }), COUNTS, []);
  expect(sentence, 'because without next-in-line items there is no "more" to speak of').toBe('Nothing runs: 12 items in the backlog lack a field.');
});

test('OnlyNextInLineLacksAField_NoBacklogClause', () => {
  const sentence = readinessSentence(readiness({ waitingOnField: 2, nextInLineMissingField: 2, blocked: 3 }), COUNTS, []);
  expect(sentence, 'because "0 more in the backlog" is noise').toBe('Nothing runs: 2 items that are next in line lack a field, 3 are blocked.');
});

test('OneItemInEachBucket_SpeaksInTheSingular', () => {
  const sentence = readinessSentence(readiness({ ready: 1, waitingOnField: 2, nextInLineMissingField: 1, gated: 1, blocked: 1 }), COUNTS, []);
  expect(sentence, 'because "1 items wait" reads as a bug').toBe('Nothing runs: 1 item is ready for the next job, 1 next in line lacks a field, 1 more in the backlog lacks one, 1 waits at a gate, 1 is blocked.');
});

test('AWorktreeRuns_NamesItsItem', () => {
  const running = { ...poolWorktree('wt-3'), state: 'running' as const, item: 'gh#41' };
  const sentence = readinessSentence(readiness({ blocked: 2 }), COUNTS, [running]);
  expect(sentence, 'because when something runs the line says what').toBe('gh#41 runs now; 2 items are blocked.');
});

test('AJobRunsWithNoWorktree_SaysAJobRuns', () => {
  const sentence = readinessSentence(readiness({}), { ...COUNTS, jobsRunning: 1 }, []);
  expect(sentence, 'because a job that runs is work going on even before it claims a worktree').toBe('1 job runs.');
});

test('NoOpenWork_SaysNothingWaits', () => {
  expect(readinessSentence(readiness({}), COUNTS, []), 'because an empty board must not read like a stall').toBe('Nothing runs, and no open item waits.');
});
