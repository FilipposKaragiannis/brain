import assert from 'node:assert/strict';
import { test } from 'node:test';
import { DisagreementSettler } from '../src/settle.ts';
import type { ReadCounts } from '../src/settle.ts';
import type { Disagreement } from '../src/snapshot.ts';

const GATE_VS_LABELS: Disagreement = {
  item: 'gh#7', worktree: null, sources: ['gate record', 'issue labels'], message: 'gh#7: the gate record says plan, the issue labels say none.',
  explain: 'x', action: null,
};
const reads = (change: Partial<ReadCounts>): ReadCounts => ({ files: 1, git: 1, processes: 1, jobs: 1, board: 1, pulls: 1, ...change });

test('Settle_FirstSeen_HeldBack', () => {
  assert.deepEqual(new DisagreementSettler().settle([GATE_VS_LABELS], reads({})), [], 'because one picture cannot tell a disagreement from a store that lags a read');
});

test('Settle_StillThereAfterBothStoresRead_Shown', () => {
  const settler = new DisagreementSettler();
  settler.settle([GATE_VS_LABELS], reads({}));
  assert.deepEqual(settler.settle([GATE_VS_LABELS], reads({ files: 2, board: 2 })), [GATE_VS_LABELS], 'because the gate files and the board were both read again and still disagree');
});

test('Settle_OnlyFilesReadAgain_HeldBack', () => {
  const settler = new DisagreementSettler();
  settler.settle([GATE_VS_LABELS], reads({}));
  assert.deepEqual(settler.settle([GATE_VS_LABELS], reads({ files: 3, processes: 5 })), [], 'because the labels come from the board, which has not been read since, so they may only be late');
});

test('Settle_GoneThenBack_StartsOver', () => {
  const settler = new DisagreementSettler();
  settler.settle([GATE_VS_LABELS], reads({}));
  settler.settle([], reads({ files: 2 }));
  assert.deepEqual(settler.settle([GATE_VS_LABELS], reads({ files: 3, board: 2 })), [], 'because it went away in between, so this is a new disagreement that has not held yet');
});
