import { cleanup, render, screen } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import type { Gate } from '../../daemon/src/snapshot.ts';
import { Gates } from '../src/screens/Gates.tsx';
import { FakeDaemon, snapshotAt, TAKEN_AT, waitingGate } from './fakeDaemon.tsx';

afterEach(cleanup);

const PULL = { number: 560, url: 'https://github.com/owner/project/pull/560', state: 'checks-failing' as const, unresolvedThreads: 2 };

function renderGate(gate: Gate): void {
  const Wrapper = new FakeDaemon().screenWrapper();
  render(<Wrapper><Gates snapshot={{ ...snapshotAt(TAKEN_AT, 1), gates: [gate] }} selected={gate.item} /></Wrapper>);
}

test('MergeGateWithAPull_LinksThePullRequest', () => {
  renderGate({ ...waitingGate('gh#310', 'merge'), pull: PULL });
  expect(screen.getByRole('link', { name: 'PR #560' }).getAttribute('href'), 'because the merge happens on the PR').toBe(PULL.url);
});

test('PullWithUnresolvedThreads_CountsThem', () => {
  renderGate({ ...waitingGate('gh#310', 'merge'), pull: PULL });
  expect(screen.queryByText('2 unresolved review threads'), 'because an open thread is why a merge gate still waits').not.toBeNull();
});

test('PullWithUnresolvedThreads_SaysTheCommentsJobHandlesThem', () => {
  renderGate({ ...waitingGate('gh#310', 'merge'), pull: PULL });
  expect(screen.queryByText(/The comments job addresses threads/), 'because the owner should know who answers the thread').not.toBeNull();
});

test('PullWithNoThreads_NoCommentsLine', () => {
  renderGate({ ...waitingGate('gh#310', 'merge'), pull: { ...PULL, unresolvedThreads: 0 } });
  expect(screen.queryByText(/The comments job addresses threads/), 'because nothing is open for the job to address').toBeNull();
});

test('GateCard_SaysWhatItsKindAsks', () => {
  renderGate(waitingGate('gh#515', 'decomposition'));
  expect(screen.queryByText(/split/), 'because the gate name alone does not say what to do').not.toBeNull();
});
