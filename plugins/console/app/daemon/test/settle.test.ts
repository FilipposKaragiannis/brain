import assert from 'node:assert/strict';
import { test } from 'node:test';
import { DisagreementSettler } from '../src/settle.ts';
import type { ReadMarks } from '../src/settle.ts';
import type { Disagreement, SourceName } from '../src/snapshot.ts';

const GATE_VS_LABELS: Disagreement = {
  item: 'gh#7', worktree: null, sources: ['gate record', 'issue labels'], message: 'gh#7: the gate record says plan, the issue labels say none.',
  explain: 'x', action: null,
};
const NONE_FAILING: Record<SourceName, boolean> = { files: false, git: false, processes: false, jobs: false, board: false, pulls: false };
/** Marks after `started` reads, with each source's latest good read having started at the number given. */
const marks = (started: number, completed: Partial<Record<SourceName, number>>, failing: Partial<Record<SourceName, boolean>> = {}): ReadMarks => ({
  started, completed: { files: 0, git: 0, processes: 0, jobs: 0, board: 0, pulls: 0, ...completed }, failing: { ...NONE_FAILING, ...failing },
});

test('Settle_FirstSeen_HeldBack', () => {
  assert.deepEqual(new DisagreementSettler().settle([GATE_VS_LABELS], marks(6, { files: 1, board: 5 })), [], 'because one picture cannot tell a disagreement from a store that lags a read');
});

test('Settle_BothStoresReadByReadsStartedLater_Shown', () => {
  const settler = new DisagreementSettler();
  settler.settle([GATE_VS_LABELS], marks(6, { files: 1, board: 5 }));
  assert.deepEqual(settler.settle([GATE_VS_LABELS], marks(8, { files: 7, board: 8 })), [GATE_VS_LABELS], 'because the gate files and the board were both read again after it appeared and still disagree');
});

test('Settle_OnlyFilesReadAgain_HeldBack', () => {
  const settler = new DisagreementSettler();
  settler.settle([GATE_VS_LABELS], marks(6, { files: 1, board: 5 }));
  assert.deepEqual(settler.settle([GATE_VS_LABELS], marks(9, { files: 9, processes: 8, board: 5 })), [], 'because the labels come from the board, which has not been read since, so they may only be late');
});

test('Settle_BoardReadInFlightWhenFirstSeen_HeldBack', () => {
  const settler = new DisagreementSettler();
  settler.settle([GATE_VS_LABELS], marks(6, { files: 6, board: 2 }));
  assert.deepEqual(settler.settle([GATE_VS_LABELS], marks(7, { files: 7, board: 5 })), [], 'because the board read that finished started (as read 5) before the gate file was seen, so it still holds the old labels');
});

test('Settle_BoardFailing_NotHeldBackOnItsAccount', () => {
  const settler = new DisagreementSettler();
  settler.settle([GATE_VS_LABELS], marks(6, { files: 1, board: 5 }));
  assert.deepEqual(settler.settle([GATE_VS_LABELS], marks(8, { files: 7, board: 5 }, { board: true })), [GATE_VS_LABELS], 'because a board that keeps failing would hold it back forever, and the red board on the sources strip says how far to trust it');
});

test('Settle_GoneThenBack_StartsOver', () => {
  const settler = new DisagreementSettler();
  settler.settle([GATE_VS_LABELS], marks(6, { files: 1, board: 5 }));
  settler.settle([], marks(7, { files: 7, board: 5 }));
  assert.deepEqual(settler.settle([GATE_VS_LABELS], marks(9, { files: 8, board: 9 })), [], 'because it went away in between, so this is a new disagreement that has not held yet');
});
