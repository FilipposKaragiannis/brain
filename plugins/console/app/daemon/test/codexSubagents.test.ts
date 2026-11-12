import assert from 'node:assert/strict';
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { codexSubagentCache, codexSubagents } from '../src/collectors/codexSubagents.ts';
import { diskSessionFiles } from '../src/collectors/sessions.ts';
import { SubagentReader } from '../src/collectors/subagents.ts';
import { LIVE_WINDOW_MS } from '../src/collectors/subagentWindow.ts';
import type { SessionRef, Subagent } from '../src/snapshot.ts';
import { FIXTURES } from './fakeRunner.ts';

/** A minute after the captured child wrote its last line, so every fixture written a minute ago is fresh. */
const NOW = new Date('2026-11-10T22:12:00Z');
const MINUTE_MS = 60000;
/** An age a minute past the live window, in the minutes `codexHome` takes. */
const PAST_THE_WINDOW_MINUTES = LIVE_WINDOW_MS / MINUTE_MS + 1;
const CODEX_FIXTURES = path.join(FIXTURES, 'subagents', 'codex');
/** The root session of the capture: a `codex exec` that spawned the `probe` child. */
const ROOT_ID = '019d-root';
const PROBE_ID = '019d-probe';

/** A home in a temp dir with the given fixture rollouts in today's day folder, each written `ageMinutes` ago (1 when not given). */
function codexHome(rollouts: Record<string, number>): { dir: string; day: string; done: () => void } {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'console-subagents-'));
  const day = path.join(dir, '.codex', 'sessions', String(NOW.getFullYear()), String(NOW.getMonth() + 1).padStart(2, '0'), String(NOW.getDate()).padStart(2, '0'));
  mkdirSync(day, { recursive: true });
  for (const [fixture, ageMinutes] of Object.entries(rollouts)) {
    const file = path.join(day, `rollout-${fixture}`);
    copyFileSync(path.join(CODEX_FIXTURES, fixture), file);
    const modified = new Date(NOW.getTime() - ageMinutes * MINUTE_MS);
    utimesSync(file, modified, modified);
  }
  return { dir, day, done: () => rmSync(dir, { recursive: true, force: true }) };
}

const rootSession = (day: string): SessionRef => ({ host: 'codex', id: ROOT_ID, transcript: path.join(day, 'rollout-parent.jsonl'), resume: ['codex', 'resume', ROOT_ID] });

/** The rows the reader lists for the root session of a home holding the parent and the given child rollouts. */
async function rootRows(children: Record<string, number>): Promise<Subagent[]> {
  const { dir, day, done } = codexHome({ 'parent.jsonl': 1, ...children });
  try {
    const reader = new SubagentReader({ home: dir, clock: () => NOW, files: diskSessionFiles });
    const [rows] = await reader.read([rootSession(day)]);
    return rows ?? [];
  } finally { done(); }
}

/** The rows of a home holding the parent and the live `probe` child alone. */
async function probeRows(): Promise<Subagent[]> {
  return rootRows({ 'child-live.jsonl': 1 });
}

test('LiveChild_ListedUnderItsRootSession', async () => {
  const rows = await rootRows({ 'child-live.jsonl': 1 });
  assert.deepEqual(rows.map((row) => row.id), [PROBE_ID], 'because a child rollout whose first line names the session as its root, and whose last turn has not completed, is a live subagent of it');
});

test('LiveChildSpawnedWithoutARole_TypeIsSubagent', async () => {
  assert.deepEqual((await probeRows()).map((row) => row.type), ['subagent'], 'because the probe was spawned with agent_role null, and a row needs a type');
});

test('LiveChild_TaskIsItsTaskNameWithItsNickname', async () => {
  assert.deepEqual((await probeRows()).map((row) => row.task), ['probe (Russell)'], 'because the spawn message is encrypted, so the task shows as the last segment of the agent path and the nickname Codex gave it');
});

test('LiveChild_CwdFromItsFirstLine', async () => {
  assert.deepEqual((await probeRows()).map((row) => row.cwd), ['/work/example'], 'because the child\'s session_meta names the folder it works in');
});

test('LiveChild_StartedAtFromItsFirstLine', async () => {
  assert.deepEqual((await probeRows()).map((row) => row.startedAt), ['2026-11-10T22:10:29.944Z'], 'because the child\'s session_meta line is stamped when it was spawned, not when its parent started');
});

test('LiveChild_LatestIsItsOwnLastLine', async () => {
  assert.deepEqual((await probeRows()).map((row) => row.latest), [{ at: '2026-11-10T22:10:36.647Z', kind: 'say', text: 'PONG' }], 'because the latest line is the last thing the child itself did');
});

test('FinishedChild_NotListed', async () => {
  const rows = await rootRows({ 'child-live.jsonl': 1, 'child-finished.jsonl': 1 });
  assert.deepEqual(rows.map((row) => row.id), [PROBE_ID], 'because a child whose last turn ended in task_complete has finished its task, though its rollout is fresh');
});

test('ChildOfAnotherSession_NotListed', async () => {
  const rows = await rootRows({ 'child-live.jsonl': 1, 'child-other-root.jsonl': 1 });
  assert.deepEqual(rows.map((row) => row.id), [PROBE_ID], 'because a child whose first line names another root session belongs to that session');
});

test('DepthTwoChild_ListedUnderTheRootSession', async () => {
  const rows = await rootRows({ 'child-depth2.jsonl': 1 });
  assert.deepEqual(rows.map((row) => row.id), ['019d-deep'], 'because a child of a child names the same root session, and the root\'s process runs it');
});

test('ChildSpawnedWithARole_TypeIsTheRole', async () => {
  const rows = await rootRows({ 'child-depth2.jsonl': 1 });
  assert.deepEqual(rows.map((row) => row.type), ['explorer'], 'because the agent role it was spawned with is the kind of subagent it is');
});

test('ChildWithOnlyReplayedLines_LatestIsNull', async () => {
  const rows = await rootRows({ 'child-replayed.jsonl': 1 });
  assert.deepEqual(rows.map((row) => row.latest), [null], 'because the lines before its history start replay the parent\'s, so a child that has done nothing yet has no latest line of its own');
});

test('ChildWithOnlyReplayedLines_StillListed', async () => {
  const rows = await rootRows({ 'child-replayed.jsonl': 1 });
  assert.deepEqual(rows.map((row) => row.id), ['019d-fresh'], 'because a child just spawned is at work before it writes a line of its own');
});

test('ChildNotWrittenForLongerThanTheLiveWindow_NotListed', async () => {
  const rows = await rootRows({ 'child-live.jsonl': PAST_THE_WINDOW_MINUTES, 'child-depth2.jsonl': 1 });
  assert.deepEqual(rows.map((row) => row.id), ['019d-deep'], 'because a rollout not written for longer than the live window is not at work, whatever its last turn says');
});

test('ChildNoLongerFresh_ItsFirstLineForgotten', async () => {
  const { dir, day, done } = codexHome({ 'parent.jsonl': 1, 'child-live.jsonl': 1 });
  try {
    let now = NOW;
    const cache = codexSubagentCache();
    const dependencies = { home: dir, clock: () => now, files: diskSessionFiles };
    await codexSubagents([rootSession(day)], dependencies, cache);
    now = new Date(NOW.getTime() + LIVE_WINDOW_MS + MINUTE_MS);
    await codexSubagents([rootSession(day)], dependencies, cache);
    assert.equal(cache.metas.has(path.join(day, 'rollout-child-live.jsonl')), false, 'because the reader runs as long as the daemon, so it must not keep the first lines of every rollout it ever saw');
  } finally { done(); }
});

/** The day folder under `dir` for `at`, made if missing, as codex names it in local time. */
function dayFolderOf(dir: string, at: Date): string {
  const folder = path.join(dir, '.codex', 'sessions', String(at.getFullYear()), String(at.getMonth() + 1).padStart(2, '0'), String(at.getDate()).padStart(2, '0'));
  mkdirSync(folder, { recursive: true });
  return folder;
}

/** Writes `text` to `file`, last modified a minute before `NOW`, so the reader takes it as fresh. */
function writtenAMinuteAgo(file: string, text: string): void {
  writeFileSync(file, text);
  const modified = new Date(NOW.getTime() - MINUTE_MS);
  utimesSync(file, modified, modified);
}

test('TwoRootSessionsReadTogether_EachListsOnlyItsOwnChild', async () => {
  const { dir, day, done } = codexHome({ 'parent.jsonl': 1, 'child-live.jsonl': 1, 'child-other-root.jsonl': 1 });
  try {
    const otherParent = path.join(day, 'rollout-other-parent.jsonl');
    writtenAMinuteAgo(otherParent, readFileSync(path.join(CODEX_FIXTURES, 'parent.jsonl'), 'utf8').replaceAll(ROOT_ID, '019d-elsewhere'));
    const otherSession: SessionRef = { host: 'codex', id: '019d-elsewhere', transcript: otherParent, resume: ['codex', 'resume', '019d-elsewhere'] };
    const reader = new SubagentReader({ home: dir, clock: () => NOW, files: diskSessionFiles });
    const lists = await reader.read([rootSession(day), otherSession]);
    assert.deepEqual(lists.map((rows) => rows.map((row) => row.id)), [[PROBE_ID], ['019d-stranger']], 'because one read serves every codex card at once, and each child names the one root it belongs to');
  } finally { done(); }
});

test('ParentStartedTheDayBefore_ItsFreshChildInThatDaysFolderListed', async () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'console-subagents-'));
  try {
    const dayBefore = new Date(NOW.getTime() - 24 * 60 * MINUTE_MS);
    const folder = dayFolderOf(dir, dayBefore);
    const [firstLine, ...rest] = readFileSync(path.join(CODEX_FIXTURES, 'parent.jsonl'), 'utf8').split('\n');
    const startedDayBefore = (firstLine ?? '').replaceAll('2026-11-10T', '2026-11-09T');
    const parent = path.join(folder, 'rollout-parent.jsonl');
    writtenAMinuteAgo(parent, [startedDayBefore, ...rest].join('\n'));
    writtenAMinuteAgo(path.join(folder, 'rollout-child-live.jsonl'), readFileSync(path.join(CODEX_FIXTURES, 'child-live.jsonl'), 'utf8'));
    const session: SessionRef = { host: 'codex', id: ROOT_ID, transcript: parent, resume: ['codex', 'resume', ROOT_ID] };
    const reader = new SubagentReader({ home: dir, clock: () => NOW, files: diskSessionFiles });
    const [rows] = await reader.read([session]);
    assert.deepEqual((rows ?? []).map((row) => row.id), [PROBE_ID], 'because codex files a rollout under the day it started, so a session running past midnight keeps children in the day before\'s folder');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('FinishedChildWithAFinalRecordOver64KiB_NotListed', async () => {
  const { dir, day, done } = codexHome({ 'parent.jsonl': 1, 'child-live.jsonl': 1 });
  try {
    const finished = readFileSync(path.join(CODEX_FIXTURES, 'child-finished.jsonl'), 'utf8').replace('"last_agent_message":"DONE"', `"last_agent_message":"${'x'.repeat(70000)}"`);
    writtenAMinuteAgo(path.join(day, 'rollout-child-finished.jsonl'), finished);
    const reader = new SubagentReader({ home: dir, clock: () => NOW, files: diskSessionFiles });
    const [rows] = await reader.read([rootSession(day)]);
    assert.deepEqual((rows ?? []).map((row) => row.id), [PROBE_ID], 'because a task_complete longer than the first tail read is still the child\'s last turn event, so the read must reach its whole line before calling the child at work');
  } finally { done(); }
});

/** The live `probe` rollout with its own turn ended by an interrupt: a `turn_aborted` after its own `task_started`. */
function probeAborted(): string {
  const live = readFileSync(path.join(CODEX_FIXTURES, 'child-live.jsonl'), 'utf8').trimEnd();
  const aborted = { timestamp: '2026-11-10T22:10:40.000Z', ordinal: 28, type: 'event_msg', payload: { type: 'turn_aborted', root_turn_id: '019d-id-03', turn_id: '019d-id-13', reason: 'interrupted' } };
  return `${live}\n${JSON.stringify(aborted)}\n`;
}

test('ChildWhoseOwnTurnWasAborted_NotListed', async () => {
  const { dir, day, done } = codexHome({ 'parent.jsonl': 1, 'child-depth2.jsonl': 1 });
  try {
    writtenAMinuteAgo(path.join(day, 'rollout-child-live.jsonl'), probeAborted());
    const reader = new SubagentReader({ home: dir, clock: () => NOW, files: diskSessionFiles });
    const [rows] = await reader.read([rootSession(day)]);
    assert.deepEqual((rows ?? []).map((row) => row.id), ['019d-deep'], 'because a child whose own last turn ended in turn_aborted was interrupted and is no longer at work, though its rollout is fresh');
  } finally { done(); }
});

test('ChildWhoseOnlyTurnEndIsItsParentsAbortedTurn_StillListed', async () => {
  const rows = await rootRows({ 'child-replayed.jsonl': 1 });
  assert.deepEqual(rows.map((row) => row.id), ['019d-fresh'], 'because the turn_aborted before its history start is the parent\'s turn replayed into the child, not the end of a turn of its own');
});

/** A fixture rollout whose first line carries `bytes` of base instructions before its history start, as codex writes them. */
function withBaseInstructions(fixture: string, bytes: number): string {
  const rollout = readFileSync(path.join(CODEX_FIXTURES, fixture), 'utf8');
  return rollout.replace('"subagent_history_start_ordinal"', `"base_instructions":{"text":"${'x'.repeat(bytes)}"},"subagent_history_start_ordinal"`);
}

/** The rows of a home holding the parent and `fixture` with its first line grown by `bytes` of base instructions. */
async function rowsWithLongFirstLine(fixture: string, bytes: number): Promise<Subagent[]> {
  const { dir, day, done } = codexHome({ 'parent.jsonl': 1 });
  try {
    writtenAMinuteAgo(path.join(day, `rollout-${fixture}`), withBaseInstructions(fixture, bytes));
    const reader = new SubagentReader({ home: dir, clock: () => NOW, files: diskSessionFiles });
    const [rows] = await reader.read([rootSession(day)]);
    return rows ?? [];
  } finally { done(); }
}

/** Over the 256 KiB the first read of a first line takes. */
const PAST_THE_HEAD_BYTES = 300 * 1024;
/** Over the 4 MiB a child's first line is read to at most. */
const PAST_THE_HEAD_CAP_BYTES = 5 * 1024 * 1024;

test('ChildWithOnlyReplayedLinesAndAFirstLineOverTheHead_ListedWithNoLatest', async () => {
  const rows = await rowsWithLongFirstLine('child-replayed.jsonl', PAST_THE_HEAD_BYTES);
  assert.deepEqual(rows.map((row) => ({ id: row.id, latest: row.latest })), [{ id: '019d-fresh', latest: null }], 'because its history start, written after the long base instructions, is read on past the head, so the parent\'s replayed spawn_agent and turn_aborted stay the parent\'s');
});

test('LiveChildWithAFirstLineOverTheHead_LatestIsItsOwnLastLine', async () => {
  const [plain] = await probeRows();
  const rows = await rowsWithLongFirstLine('child-live.jsonl', PAST_THE_HEAD_BYTES);
  assert.deepEqual(rows.map((row) => row.latest), [plain?.latest], 'because the history start is recovered from the longer read, so the child\'s own latest line still shows rather than being withheld');
});

test('ChildWithOnlyReplayedLinesAndAFirstLineOverTheCap_ListedWithNoLatest', async () => {
  const rows = await rowsWithLongFirstLine('child-replayed.jsonl', PAST_THE_HEAD_CAP_BYTES);
  assert.deepEqual(rows.map((row) => ({ id: row.id, latest: row.latest })), [{ id: '019d-fresh', latest: null }], 'because with its history start unknown any line may replay the parent\'s, so none shows as its latest and the parent\'s turn_aborted does not end it');
});
