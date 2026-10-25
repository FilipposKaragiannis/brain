import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from 'node:fs';
import type { AddressInfo } from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { planAction } from '../src/actionPlan.ts';
import type { ActionContext } from '../src/actionPlan.ts';
import { ActionRunner, realScheduler } from '../src/actions.ts';
import type { CommandRunner } from '../src/collectors/exec.ts';
import { claudeProjectFolder, codexMeta, diskSessionFiles, parseTranscript, SessionLocator } from '../src/collectors/sessions.ts';
import type { SessionFiles, SessionProcess } from '../src/collectors/sessions.ts';
import { silentLogger } from '../src/log.ts';
import { FlowConfigEditor } from '../src/plugins/flow/configEditor.ts';
import { ProjectMonitor } from '../src/project.ts';
import { ProjectRegistry } from '../src/registry.ts';
import { closeConsoleServer, createConsoleServer } from '../src/server.ts';
import type { SessionRef, TranscriptTurn } from '../src/snapshot.ts';
import { FIXTURE_ROOT, FIXTURES, fakeRunner } from './fakeRunner.ts';
import { plainSpawner } from './fakeSpawner.ts';

const NOW = new Date('2026-10-24T18:16:04Z');
const MINUTE_MS = 60000;
const TRANSCRIPT = path.join(FIXTURES, 'transcripts', 'claude.jsonl');

/** A home folder in a temp dir, so no test reads the owner's own ~/.claude or ~/.codex. */
function home(): { dir: string; done: () => void } {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'console-home-'));
  return { dir, done: () => rmSync(dir, { recursive: true, force: true }) };
}

function written(file: string, text: string, modified: Date): void {
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, text);
  utimesSync(file, modified, modified);
}

const locator = (dir: string, files: SessionFiles = diskSessionFiles) => new SessionLocator({ home: dir, clock: () => NOW, files });

/** The session the locator gives one process on its own. */
async function one(found: SessionLocator, process: Omit<SessionProcess, 'pid'> & { pid?: number }) {
  return (await found.assign([{ pid: 4242, ...process }]))[0] ?? null;
}

/** `~/.claude/sessions/<pid>.json` in the shape claude writes it (procStart as ps prints lstart, local time). */
function sessionsFile(dir: string, pid: number, sessionId: string, cwd: string, startedAt: Date): void {
  const procStart = startedAt.toString().replace(/^(\w{3}) (\w{3}) (\d{2}) (\d{4}) ([\d:]{8}).*$/, (_all, day, month, date, year, clock) => `${day} ${month} ${Number(date)} ${clock} ${year}`);
  written(path.join(dir, '.claude', 'sessions', `${pid}.json`), JSON.stringify({ pid, sessionId, cwd, startedAt: startedAt.getTime(), procStart, kind: 'interactive', entrypoint: 'cli' }), NOW);
}

test('ClaudeFolder_EveryNonAlphanumericBecomesADash', () => {
  assert.equal(path.basename(claudeProjectFolder('/h', '/work/projects/foosbrawl-wt-3')), '-work-projects-foosbrawl-wt-3', 'because claude names a folder\'s transcripts after its path that way');
});

test('ClaudeProcessWithoutASessionsFile_NewestTranscriptSinceItStarted_IsItsSession', async () => {
  const { dir, done } = home();
  try {
    const folder = claudeProjectFolder(dir, '/p/app-wt-2');
    written(path.join(folder, 'older-before-start.jsonl'), '{}\n', new Date(NOW.getTime() - 60 * MINUTE_MS));
    written(path.join(folder, 'aaaa-1111.jsonl'), '{}\n', new Date(NOW.getTime() - 5 * MINUTE_MS));
    written(path.join(folder, 'bbbb-2222.jsonl'), '{}\n', new Date(NOW.getTime() - MINUTE_MS));
    const session = await one(locator(dir), { host: 'claude', cwd: '/p/app-wt-2', elapsedSeconds: 600 });
    assert.deepEqual(session, { host: 'claude', id: 'bbbb-2222', transcript: path.join(folder, 'bbbb-2222.jsonl'), resume: ['claude', '--resume', 'bbbb-2222'] }, 'because the newest transcript written since the process started is the one it writes, and its name is the id claude --resume takes');
  } finally { done(); }
});

test('ClaudeProcess_OnlyTranscriptsOlderThanIt_NoSession', async () => {
  const { dir, done } = home();
  try {
    written(path.join(claudeProjectFolder(dir, '/p/app-wt-2'), 'old.jsonl'), '{}\n', new Date(NOW.getTime() - 60 * MINUTE_MS));
    assert.equal(await one(locator(dir), { host: 'claude', cwd: '/p/app-wt-2', elapsedSeconds: 60 }), null, 'because a transcript from before the process started belongs to an earlier run');
  } finally { done(); }
});

test('ClaudeProcessWithASessionsFile_ItsSessionIdWinsOverFileTimes', async () => {
  const { dir, done } = home();
  try {
    const folder = claudeProjectFolder(dir, '/p/app');
    written(path.join(folder, 'mine-1111.jsonl'), '{}\n', new Date(NOW.getTime() - 5 * MINUTE_MS));
    written(path.join(folder, 'owners-2222.jsonl'), '{}\n', new Date(NOW.getTime() - MINUTE_MS));
    sessionsFile(dir, 100, 'mine-1111', '/p/app', new Date(NOW.getTime() - 600 * 1000));
    const session = await one(locator(dir), { pid: 100, host: 'claude', cwd: '/p/app', elapsedSeconds: 600 });
    assert.deepEqual([session?.id, session?.transcript], ['mine-1111', path.join(folder, 'mine-1111.jsonl')], 'because claude names the session of each pid itself, and a newer transcript in the same folder may be the owner\'s own');
  } finally { done(); }
});

test('SessionsFileFromAnEarlierProcessWithThePid_Ignored', async () => {
  const { dir, done } = home();
  try {
    sessionsFile(dir, 100, 'earlier-1', '/p/app', new Date(NOW.getTime() - 5 * 3600 * 1000));
    assert.equal(await one(locator(dir), { pid: 100, host: 'claude', cwd: '/p/app', elapsedSeconds: 60 }), null, 'because a pid reused since names another process, whose session is not this one');
  } finally { done(); }
});

test('TwoClaudeProcessesInOneFolder_OneTranscriptNeverGoesToBoth', async () => {
  const { dir, done } = home();
  try {
    const folder = claudeProjectFolder(dir, '/p/app');
    written(path.join(folder, 'owners-2222.jsonl'), '{}\n', new Date(NOW.getTime() - MINUTE_MS));
    sessionsFile(dir, 300, 'owners-2222', '/p/app', new Date(NOW.getTime() - 3600 * 1000));
    const sessions = await locator(dir).assign([
      { pid: 100, host: 'claude', cwd: '/p/app', elapsedSeconds: 600 },
      { pid: 300, host: 'claude', cwd: '/p/app', elapsedSeconds: 3600 },
      { pid: 101, host: 'claude', cwd: '/p/app', elapsedSeconds: 600 },
    ]);
    assert.deepEqual(sessions.map((session) => session?.id ?? null), [null, 'owners-2222', null], 'because Open session on the agent must never resume the owner\'s live session, which its sessions file names');
  } finally { done(); }
});

test('FolderScan_DoneOncePerProcess', async () => {
  const { dir, done } = home();
  try {
    written(path.join(claudeProjectFolder(dir, '/p/app'), 'run-1.jsonl'), '{}\n', new Date(NOW.getTime() - MINUTE_MS));
    let listed = 0;
    const counting: SessionFiles = { ...diskSessionFiles, list: async (folder) => { listed += 1; return diskSessionFiles.list(folder); } };
    const found = locator(dir, counting);
    const process = { pid: 100, host: 'claude' as const, cwd: '/p/app', elapsedSeconds: 600 };
    await found.assign([process]);
    const again = await found.assign([process]);
    assert.deepEqual([listed, again[0]?.id], [1, 'run-1'], 'because the folder can hold hundreds of transcripts and the processes source reads every ten seconds');
  } finally { done(); }
});

const meta = (id: string, cwd: string) => JSON.stringify({ timestamp: '2026-10-24T18:00:00Z', type: 'session_meta', payload: { session_id: id, id, cwd, originator: 'codex_exec', base_instructions: { text: 'You are Codex.' } } });

test('CodexProcess_SessionFileWithItsCwd_IsItsSession', async () => {
  const { dir, done } = home();
  try {
    const day = path.join(dir, '.codex', 'sessions', String(NOW.getFullYear()), String(NOW.getMonth() + 1).padStart(2, '0'), String(NOW.getDate()).padStart(2, '0'));
    written(path.join(day, 'rollout-a-019c-mine.jsonl'), `${meta('019c-mine', '/p/app-wt-3')}\n{"type":"event_msg"}\n`, new Date(NOW.getTime() - 2 * MINUTE_MS));
    written(path.join(day, 'rollout-b-019c-other.jsonl'), `${meta('019c-other', '/elsewhere')}\n`, new Date(NOW.getTime() - MINUTE_MS));
    written(path.join(dir, '.codex', 'session_index.jsonl'), '{"id":"019c-mine","thread_name":"Fix nine","updated_at":"2026-10-24T18:14:00Z"}\n', NOW);
    const session = await one(locator(dir), { host: 'codex', cwd: '/p/app-wt-3', elapsedSeconds: 600 });
    assert.deepEqual(session?.id, '019c-mine', 'because the newer file belongs to another folder, and the first line of a session file names its cwd');
    assert.deepEqual(session?.resume, ['codex', 'resume', '019c-mine'], 'because codex resume takes the session id');
  } finally { done(); }
});

test('CodexSessionFilesRemembered_ForgottenAfterFourteenDays', async () => {
  const { dir, done } = home();
  try {
    const day = path.join(dir, '.codex', 'sessions', String(NOW.getFullYear()), String(NOW.getMonth() + 1).padStart(2, '0'), String(NOW.getDate()).padStart(2, '0'));
    written(path.join(day, 'rollout-a-019c-mine.jsonl'), `${meta('019c-mine', '/p/app-wt-3')}\n`, new Date(NOW.getTime() - MINUTE_MS));
    let now = NOW;
    const found = new SessionLocator({ home: dir, clock: () => now, files: diskSessionFiles });
    await found.assign([{ pid: 7, host: 'codex', cwd: '/p/app-wt-3', elapsedSeconds: 600 }]);
    assert.equal(found.codexFilesKept, 1, 'because a session file\'s first line is read once');
    now = new Date(NOW.getTime() + 15 * 86400000);
    await found.assign([]);
    assert.equal(found.codexFilesKept, 0, 'because the memory of session files must not grow for as long as the daemon runs');
  } finally { done(); }
});

test('CodexMeta_FirstLineLongerThanTheHead_StillRead', () => {
  const line = meta('019c-long', '/p/app-wt-3').replace('You are Codex.', 'x'.repeat(1000));
  assert.deepEqual(codexMeta(line.slice(0, 400)), { cwd: '/p/app-wt-3', id: '019c-long' }, 'because the id and cwd come before the long base instructions the head may cut');
});

test('Transcript_TextTurnsOfUserAndAssistant_OldestFirst', () => {
  const turns = parseTranscript(readFileSync(TRANSCRIPT, 'utf8'), 200);
  assert.deepEqual(turns, [
    { at: '2026-10-24T17:00:01.000Z', role: 'user', text: '/flow:next gh#9' },
    { at: '2026-10-24T17:00:05.000Z', role: 'assistant', text: 'Starting gh#9 at the implement step.' },
    { at: '2026-10-24T17:00:09.000Z', role: 'assistant', text: 'The tree is clean.\nWriting the test first.' },
    { at: '2026-10-24T17:00:15.000Z', role: 'user', text: 'Keep going, and use <b> tags in the docs.' },
  ], 'because meta lines, tool calls, tool results, thinking, a subagent\'s side chain and the host\'s wrapper turns (task notifications, local commands, compaction summaries) carry no turn the owner reads');
});

test('Transcript_Limit_KeepsTheLastTurns', () => {
  assert.deepEqual(parseTranscript(readFileSync(TRANSCRIPT, 'utf8'), 1).map((turn) => turn.text), ['Keep going, and use <b> tags in the docs.'], 'because the fold shows where the run is now');
});

const SESSION: SessionRef = { host: 'claude', id: '8f3c2a10-5b7e-4c1d-9a0b-1e2f3a4b5c6d', transcript: TRANSCRIPT, resume: ['claude', '--resume', '8f3c2a10-5b7e-4c1d-9a0b-1e2f3a4b5c6d'] };
const CONTEXT: ActionContext = {
  root: '/p/app', pluginRoot: '/plugins/flow/1.19.0', repo: 'o/r', jobsHost: 'claude', pool: ['/p/app-wt-2'], outsideWorktrees: [], processCwds: ['/p/app-wt-2'],
  sessions: [{ pid: 100, cwd: '/p/app-wt-2', session: SESSION, alive: true }, { pid: 200, cwd: '/p/app-wt-2', session: { ...SESSION, id: 'ended-1', resume: ['claude', '--resume', 'ended-1'] }, alive: false }],
  terminal: 'iterm', installedTerminals: ['iterm'], base: 'main', worktrees: [], runItems: [],
};

function launch(args: Record<string, string>, context: ActionContext = CONTEXT): string[] {
  const result = planAction('terminal.open', args, context);
  assert.ok(result.ok, `because ${JSON.stringify(args)} names a listed session in its own folder: ${result.ok ? '' : result.error}`);
  return result.ok ? [result.plan.command, ...result.plan.args] : [];
}

test('LiveSessionInIterm_ResumeTypedButNotRun', () => {
  const argv = launch({ path: '/p/app-wt-2', session: '100' });
  assert.equal(argv[0], 'osascript', 'because iTerm is driven through AppleScript');
  assert.ok(argv.includes(`write text "claude --resume ${SESSION.id}" newline NO`), 'because a resume while the run still writes the session would put two writers on it, so Enter is the owner\'s');
  assert.ok(argv.includes('write text "cd \'/p/app-wt-2\'"'), 'because claude --resume finds a session by the folder it ran in');
});

test('EndedSessionInIterm_ResumeRunsAtOnce', () => {
  const argv = launch({ path: '/p/app-wt-2', session: '200' });
  assert.ok(argv.includes('write text "claude --resume ended-1"'), 'because once the run has ended the owner wants to be in the session straight away');
  assert.ok(!argv.some((word) => word.includes('newline NO')), 'because nothing waits for the owner to press Enter');
});

test('LiveSessionInTerminal_CommandPrintedNotRun', () => {
  const argv = launch({ path: '/p/app-wt-2', session: '100' }, { ...CONTEXT, terminal: 'terminal' });
  assert.equal(argv[2], `tell application "Terminal" to do script "cd '/p/app-wt-2' && echo 'The run is still going. Once it ends, resume its session with:' && echo 'claude --resume ${SESSION.id}'"`, 'because Terminal cannot type without running, so it shows the command and leaves the shell');
});

test('EndedSessionInGhostty_RunsAndKeepsAShell', () => {
  const argv = launch({ path: '/p/app-wt-2', session: '200' }, { ...CONTEXT, terminal: 'ghostty' });
  assert.deepEqual(argv.slice(-2), ['-e', `cd '/p/app-wt-2' && claude --resume ended-1; exec "\${SHELL:-/bin/sh}" -l`], 'because the session resumes at once and the window stays a shell after it');
});

test('SessionOfAnUnknownPidOrInAnotherFolder_Refused', () => {
  assert.equal(planAction('terminal.open', { path: '/p/app-wt-2', session: '999' }, CONTEXT).ok, false, 'because only a session the snapshot lists may be resumed');
  assert.equal(planAction('terminal.open', { path: '/p/app', session: '100' }, CONTEXT).ok, false, 'because claude --resume run elsewhere would not find the session');
  assert.equal(planAction('terminal.open', { path: '/p/app-wt-2', session: '100', job: 'next' }, CONTEXT).ok, false, 'because a window follows a log or opens a session, not both');
});

/** The fake runner, with the process list it answers changed by the test. */
function changingProcesses(): { runner: CommandRunner; drop: (pid: number) => void } {
  const dropped = new Set<number>();
  const runner: CommandRunner = async (request) => {
    const result = await fakeRunner(request);
    if (request.command !== 'ps') return result;
    return { ...result, stdout: result.stdout.split('\n').filter((line) => !dropped.has(Number(line.trim().split(/\s+/)[0]))).join('\n') };
  };
  return { runner, drop: (pid) => dropped.add(pid) };
}

const sessionsByPid = { assign: async (processes: { host: string }[]) => processes.map((process) => (process.host === 'claude' ? SESSION : null)) };

test('AgentWithATranscript_SnapshotCarriesItsSession', async () => {
  const monitor = new ProjectMonitor({ project: { id: 'project', name: 'project', root: FIXTURE_ROOT }, runner: fakeRunner, clock: () => NOW, log: silentLogger, cadence: { filesMs: 1e9, gitMs: 1e9, processesMs: 1e9, jobsMs: 1e9, boardMs: 1e9, pullsMs: 1e9 }, sessions: sessionsByPid });
  await monitor.refresh('files');
  await monitor.refresh('processes');
  const agent = monitor.snapshot?.agents.find((entry) => entry.pid === 100);
  assert.deepEqual(agent?.session, SESSION, 'because the agent row offers its session');
  assert.deepEqual(monitor.snapshot?.worktrees.find((entry) => entry.name === 'project-wt-3')?.agents[0]?.session, SESSION, 'because the worktree card carries the same session');
});

test('AgentGoneFromTheProcessList_ListedAsEndedWithItsSession', async () => {
  const { runner, drop } = changingProcesses();
  const monitor = new ProjectMonitor({ project: { id: 'project', name: 'project', root: FIXTURE_ROOT }, runner, clock: () => NOW, log: silentLogger, cadence: { filesMs: 1e9, gitMs: 1e9, processesMs: 1e9, jobsMs: 1e9, boardMs: 1e9, pullsMs: 1e9 }, sessions: sessionsByPid });
  await monitor.refresh('files');
  await monitor.refresh('processes');
  drop(100);
  await monitor.refresh('processes');
  assert.deepEqual(monitor.snapshot?.ended.map((entry) => [entry.pid, entry.worktree, entry.endedAt, entry.session?.id]), [[100, 'project-wt-3', NOW.toISOString(), SESSION.id]], 'because a run that ended leaves a session the owner can resume');
  assert.deepEqual(monitor.actionContext().sessions.map((entry) => [entry.pid, entry.alive]), [[104, true], [100, false]], 'because an ended run\'s session resumes at once, a live one waits for Enter');
});

async function transcriptServer(): Promise<{ base: string; close: () => Promise<void> }> {
  const { spawner } = plainSpawner();
  const registry = new ProjectRegistry((project) => {
    const monitor = new ProjectMonitor({ project, runner: fakeRunner, clock: () => NOW, log: silentLogger, cadence: { filesMs: 1e9, gitMs: 1e9, processesMs: 1e9, jobsMs: 1e9, boardMs: 1e9, pullsMs: 1e9 }, sessions: sessionsByPid });
    const actions = new ActionRunner({ projectId: project.id, context: () => monitor.actionContext(), spawner, scheduler: realScheduler, clock: () => NOW, log: silentLogger, stateDir: os.tmpdir(), onRefresh: () => {} });
    return { monitor, actions, flowConfig: new FlowConfigEditor({ projectId: project.id, root: project.root, runner: fakeRunner, refresh: async () => {}, log: silentLogger }) };
  }, silentLogger);
  const server = createConsoleServer(registry, null, { host: '127.0.0.1', port: 0, token: 'tok', staticDir: null, log: silentLogger });
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', resolve));
  await registry.apply([{ id: 'project', name: 'project', root: FIXTURE_ROOT }]);
  const { port } = server.address() as AddressInfo;
  return { base: `http://127.0.0.1:${port}`, close: async () => { registry.stopAll(); await closeConsoleServer(server); } };
}

test('TranscriptRoute_LastTurnsOfTheAgentsClaudeSession', async () => {
  const { base, close } = await transcriptServer();
  try {
    const response = await fetch(`${base}/api/projects/project/agents/100/transcript?lines=2`, { headers: { authorization: 'Bearer tok' } });
    const body = (await response.json()) as { turns: TranscriptTurn[] };
    assert.equal(response.status, 200, 'because pid 100 is a listed agent with a claude transcript');
    assert.deepEqual(body.turns.map((turn) => turn.text), ['The tree is clean.\nWriting the test first.', 'Keep going, and use <b> tags in the docs.'], 'because lines asks for the last two turns with text, the wrapper turns between them left out');
  } finally { await close(); }
});

test('TranscriptRoute_PidNotListedOrBadLines_Refused', async () => {
  const { base, close } = await transcriptServer();
  try {
    const get = (rest: string) => fetch(`${base}/api/projects/project/agents/${rest}`, { headers: { authorization: 'Bearer tok' } });
    assert.equal((await get('4242/transcript')).status, 404, 'because only a transcript the daemon found for a listed process is read, never a path from the request');
    assert.equal((await get('100/transcript?lines=0')).status, 400, 'because lines is a positive count');
  } finally { await close(); }
});
