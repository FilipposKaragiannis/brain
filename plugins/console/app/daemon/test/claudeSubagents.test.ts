import assert from 'node:assert/strict';
import { cpSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { diskSessionFiles } from '../src/collectors/sessions.ts';
import { LIVE_WINDOW_MS } from '../src/collectors/subagentWindow.ts';
import { SubagentReader } from '../src/collectors/subagents.ts';
import type { SessionRef, Subagent } from '../src/snapshot.ts';
import { FIXTURES } from './fakeRunner.ts';

const NOW = new Date('2026-10-24T18:16:00Z');
const MINUTE_MS = 60000;
const SESSION_ID = '00000000-0000-4000-8000-000000000001';
const PROJECT = '-work-example';
const CLAUDE_FIXTURES = path.join(FIXTURES, 'subagents', 'claude');
/** The live reviewer: no `finished`, its jsonl written a minute ago. */
const LIVE = 'a1111111111111111';
/** The explorer: its meta says `finished: true`. */
const FINISHED = 'a2222222222222222';
/** The planner: no `finished`, but its jsonl last written days ago. */
const STALE = 'a3333333333333333';

type ClaudeHome = { dir: string; subagents: string; session: SessionRef; done: () => void };

/** How long ago each agent's jsonl was written unless a test says otherwise: the stale planner four days ago, the rest a minute ago. */
const DEFAULT_AGE_MS: Record<string, number> = { [LIVE]: MINUTE_MS, [FINISHED]: MINUTE_MS, [STALE]: 4 * 24 * 60 * MINUTE_MS };

/** A home in a temp dir holding the fixture session folder, each agent's jsonl written `ageMs` before now (`DEFAULT_AGE_MS` when not given). */
function claudeHome(ageMs: Record<string, number> = {}): ClaudeHome {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'console-claude-subagents-'));
  const project = path.join(dir, '.claude', 'projects', PROJECT);
  cpSync(path.join(CLAUDE_FIXTURES, PROJECT), project, { recursive: true });
  const transcript = path.join(project, `${SESSION_ID}.jsonl`);
  writeFileSync(transcript, '');
  const subagents = path.join(project, SESSION_ID, 'subagents');
  for (const agent of [LIVE, FINISHED, STALE]) touch(path.join(subagents, `agent-${agent}.jsonl`), ageMs[agent] ?? DEFAULT_AGE_MS[agent] ?? MINUTE_MS);
  touch(path.join(subagents, 'workflows', 'wf_00000000-000', 'agent-a4444444444444444.jsonl'), MINUTE_MS);
  const session: SessionRef = { host: 'claude', id: SESSION_ID, transcript, resume: ['claude', '--resume', SESSION_ID] };
  return { dir, subagents, session, done: () => rmSync(dir, { recursive: true, force: true }) };
}

function touch(file: string, ageMs: number, now: Date = NOW): void {
  const modified = new Date(now.getTime() - ageMs);
  utimesSync(file, modified, modified);
}

/** Rewrites one agent's meta with the given fields changed, stamped `at`. */
function editMeta(subagents: string, agent: string, change: Record<string, unknown>, at: Date = NOW): void {
  const file = path.join(subagents, `agent-${agent}.meta.json`);
  writeFileSync(file, JSON.stringify({ ...JSON.parse(readFileSync(file, 'utf8')), ...change }));
  utimesSync(file, at, at);
}

const readerOf = (home: ClaudeHome, clock: () => Date = () => NOW) => new SubagentReader({ home: home.dir, clock, files: diskSessionFiles });

/** The rows one read lists for the fixture session, after `prepare` changed the home. */
async function rowsOf(prepare: (home: ClaudeHome) => void = () => {}, ageMs: Record<string, number> = {}): Promise<Subagent[]> {
  const home = claudeHome(ageMs);
  try {
    prepare(home);
    const [rows] = await readerOf(home).read([home.session]);
    return rows ?? [];
  } finally { home.done(); }
}

/** One field of every row the untouched fixture session lists: the live reviewer's alone. */
const fieldOfRows = async <Key extends keyof Subagent>(key: Key): Promise<Subagent[Key][]> => (await rowsOf()).map((row) => row[key]);

test('ClaudeSession_OnlyTheLiveSubagentListed', async () => {
  assert.deepEqual((await rowsOf()).map((row) => row.id), [LIVE], 'because a finished agent, a stale one and a workflow step are not live subagents of the session');
});

test('ClaudeLiveSubagent_HostIsClaude', async () => {
  assert.deepEqual(await fieldOfRows('host'), ['claude'], 'because the row came from a claude session');
});

test('ClaudeLiveSubagent_TypeIsItsAgentType', async () => {
  assert.deepEqual(await fieldOfRows('type'), ['example-reviewer'], 'because the meta names the agent type it was spawned as');
});

test('ClaudeLiveSubagent_TaskIsItsDescription', async () => {
  assert.deepEqual(await fieldOfRows('task'), ['Review the example change'], 'because the meta description is the task it was given');
});

test('ClaudeLiveSubagent_CwdFromItsFirstLine', async () => {
  assert.deepEqual(await fieldOfRows('cwd'), ['/work/example'], 'because the first transcript line names the folder the agent works in');
});

test('ClaudeLiveSubagent_StartedAtFromItsFirstLine', async () => {
  assert.deepEqual(await fieldOfRows('startedAt'), ['2026-10-24T18:10:00.000Z'], 'because the first transcript line is stamped when the agent was spawned, not when it last wrote');
});

test('ClaudeLiveSubagent_LatestIsItsLastSideChainLine', async () => {
  assert.deepEqual(await fieldOfRows('latest'), [{ at: '2026-10-24T18:15:30.000Z', kind: 'say', text: 'The example change reads cleanly so far.' }], 'because every subagent line is a side chain, and the last one it said is its latest');
});

test('ClaudeSubagentMetaWithoutDescription_TaskNull', async () => {
  const rows = await rowsOf(({ subagents }) => editMeta(subagents, LIVE, { description: undefined }));
  assert.deepEqual(rows.map((row) => row.task), [null], 'because an agent spawned without a description has no task to show');
});

test('ClaudeSubagentStoppedByUser_NotListed', async () => {
  const rows = await rowsOf(({ subagents }) => editMeta(subagents, LIVE, { stoppedByUser: true }));
  assert.deepEqual(rows, [], 'because an agent the user stopped is no longer running, though its jsonl is fresh');
});

test('ClaudeFinishedSubagentWrittenRecently_NotListed', async () => {
  const rows = await rowsOf(() => {}, { [FINISHED]: 0 });
  assert.deepEqual(rows.map((row) => row.id), [LIVE], 'because finished: true drops an agent however fresh its jsonl is');
});

for (const { name, ageMs, listed } of [
  { name: 'ClaudeSubagentWrittenAMinuteInsideTheLiveWindow_Listed', ageMs: LIVE_WINDOW_MS - MINUTE_MS, listed: [STALE] },
  { name: 'ClaudeSubagentWrittenAMinuteOutsideTheLiveWindow_NotListed', ageMs: LIVE_WINDOW_MS + MINUTE_MS, listed: [] },
]) {
  test(name, async () => {
    const rows = await rowsOf(({ subagents }) => touch(path.join(subagents, `agent-${LIVE}.jsonl`), LIVE_WINDOW_MS * 10), { [STALE]: ageMs });
    assert.deepEqual(rows.map((row) => row.id), listed, 'because an agent without finished counts as live only while its jsonl was written within the live window');
  });
}

test('ClaudeSessionWithoutASubagentsFolder_NoRows', async () => {
  const rows = await rowsOf(({ subagents }) => rmSync(subagents, { recursive: true, force: true }));
  assert.deepEqual(rows, [], 'because a session that spawned no agent has no subagents folder');
});

test('ClaudeTwoLiveSubagents_OldestStartedFirst', async () => {
  const rows = await rowsOf(({ subagents }) => editMeta(subagents, FINISHED, { finished: false }), { [FINISHED]: 0 });
  assert.deepEqual(rows.map((row) => row.id), [FINISHED, LIVE], 'because the explorer started at 18:08 and the reviewer at 18:10, so the explorer comes first though its id sorts last');
});

test('ClaudeSubagentFinishesBetweenReads_DroppedOnTheNextRead', async () => {
  const home = claudeHome();
  try {
    const reader = readerOf(home);
    await reader.read([home.session]);
    editMeta(home.subagents, LIVE, { finished: true }, new Date(NOW.getTime() + MINUTE_MS));
    const [rows] = await reader.read([home.session]);
    assert.deepEqual(rows, [], 'because the meta changed after the first read, so the reader must not keep the live meta it saw before');
  } finally { home.done(); }
});

test('ClaudeSubagentStopsWriting_DroppedOnceTheLiveWindowPasses', async () => {
  const home = claudeHome();
  try {
    let now = NOW;
    const reader = readerOf(home, () => now);
    await reader.read([home.session]);
    now = new Date(NOW.getTime() + LIVE_WINDOW_MS);
    const [rows] = await reader.read([home.session]);
    assert.deepEqual(rows, [], 'because the reviewer last wrote a minute before the first read, so a live window later it is past the window');
  } finally { home.done(); }
});

test('SubagentReader_OneListPerSessionInOrderAndNoneForANullSession', async () => {
  const home = claudeHome();
  try {
    const rows = await readerOf(home).read([null, home.session, null]);
    assert.deepEqual(rows.map((list) => list.map((row) => row.id)), [[], [LIVE], []], 'because each list belongs to the session at the same place, and a process with no session has no subagents');
  } finally { home.done(); }
});
