import assert from 'node:assert/strict';
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, utimesSync } from 'node:fs';
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
