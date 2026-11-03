import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import type { ActionRecord, Agent, EndedAgent, Job, Run, SessionRef, Snapshot } from '../../daemon/src/snapshot.ts';
import { Agents, STOP_HELP } from '../src/screens/Agents.tsx';
import { OPEN_SESSION_ENDED, OPEN_SESSION_LIVE } from '../src/ui.tsx';
import { FakeDaemon, HTTP_ACCEPTED, HTTP_OK, actionRecord, snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

afterEach(cleanup);

const ACTIONS_PATH = '/api/projects/project/actions';

function agent(pid: number, kind: Agent['kind'], cwd: string): Agent {
  return { pid, host: 'claude', kind, cwd, worktree: null, item: null, elapsedSeconds: 60, command: `claude ${pid}`, session: null };
}

const JOB: Job = { name: 'next', job: 'next', host: 'claude', configured: true, state: 'scheduled', schedule: 'every 30m', args: '', installed: true, loaded: true, paused: false, running: [], last: null, recent: [], workers: [], next: '18:30', runsThisWeek: 0, failedThisWeek: 0 };

const SESSION: SessionRef = { host: 'claude', id: '8f3c', transcript: '/h/.claude/projects/-p-wt-wt-3/8f3c.jsonl', resume: ['claude', '--resume', '8f3c'] };

async function renderAgents(agents: Agent[], ended: EndedAgent[] = [], daemon = new FakeDaemon()): Promise<unknown[]> {
  const posted: unknown[] = [];
  daemon.answer('POST', ACTIONS_PATH, (body) => { posted.push(body); return { status: HTTP_ACCEPTED, body: { action: { ...actionRecord('t1', 'running', {}), kind: 'terminal.open', args: (body as { args: Record<string, string> }).args } } }; });
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><Agents snapshot={{ ...snapshotAt(TAKEN_AT, 0), agents, ended }} /></Wrapper>);
  await act(async () => {});
  return posted;
}

async function renderSnapshot(extra: Partial<Snapshot>, daemon = new FakeDaemon(), clock?: () => number): Promise<unknown[]> {
  const posted: unknown[] = [];
  daemon.answer('POST', ACTIONS_PATH, (body) => {
    posted.push(body);
    const { kind, args } = body as { kind: ActionRecord['kind']; args: Record<string, string> };
    return { status: HTTP_ACCEPTED, body: { action: { ...actionRecord('p1', 'done', {}), kind, args, outcome: 'finished' } } };
  });
  const Wrapper = daemon.screenWrapper(clock);
  render(<Wrapper><Agents snapshot={{ ...snapshotAt(TAKEN_AT, 0), ...extra }} /></Wrapper>);
  await act(async () => {});
  return posted;
}

const LINES = [{ at: TAKEN_AT, kind: 'tool', text: 'Bash · npm test' }, { at: TAKEN_AT, kind: 'say', text: 'Running the gates.' }];

function transcriptAt(daemon: FakeDaemon, lines: number): void {
  daemon.answer('GET', `/api/projects/project/agents/100/transcript?lines=${lines}`, () => ({ status: HTTP_OK, body: { turns: [], lines: LINES, bytes: 1_290_000, turnCount: 212 } }));
}

test('AgentsScreen_AnySnapshot_RunsIsAPlainModule', async () => {
  await renderSnapshot({ jobs: [JOB] });
  const runs = screen.getByRole('heading', { name: 'Runs' });
  expect(runs.closest('details'), 'because Runs is the page itself, so it does not fold').toBeNull();
  expect(runs.closest('section.module'), 'because Runs is a module like the others on the page').not.toBeNull();
});

test('AgentsScreen_WithJobs_ShowsNoJobsListPanelOrEvents', async () => {
  await renderSnapshot({ jobs: [JOB], stoppedHosts: [{ host: 'codex', cause: 'auth', said: '', at: TAKEN_AT, item: null }] });
  expect(screen.queryByRole('listitem', { name: 'Job next' }), 'because the schedules live on the Jobs page').toBeNull();
  expect(screen.queryByRole('tab', { name: 'Run once' }), 'because the schedule and run once panel lives on the Jobs page').toBeNull();
  expect(screen.queryByRole('heading', { name: 'Events' }), 'because the events sit beside the jobs, not the runs').toBeNull();
  expect(screen.queryByRole('region', { name: 'codex is stopped' }), 'because a stopped host stops jobs, so it shows with them').toBeNull();
});

test('AgentsScreen_NoRun_EmptyStatePointsToJobs', async () => {
  await renderSnapshot({});
  expect(screen.getByRole('link', { name: 'Jobs' }).getAttribute('href'), 'because a run is started from the Run once panel, which is on the Jobs page').toBe('#/project/jobs');
});

test('AgentsScreen_AgentAndSessionRows_EachOpenTheirOwnFolder', async () => {
  const posted = await renderAgents([agent(100, 'agent', '/p-wt/wt-3'), agent(104, 'session', '/p-wt/wt-2/src')]);
  const row = screen.getByRole('listitem', { name: 'Session 104' });
  await act(async () => { fireEvent.click(within(row).getByRole('button', { name: 'Open in Terminal' })); });
  expect(screen.getAllByRole('button', { name: /Open in Terminal/ }).length, 'because a run card and a session row each get the button').toBe(2);
  expect(posted, 'because the terminal opens where that process works').toEqual([{ kind: 'terminal.open', args: { path: '/p-wt/wt-2/src' } }]);
});

test('OwnSessions_FoldUnderACount', async () => {
  await renderAgents([agent(100, 'agent', '/p-wt/wt-3'), agent(104, 'session', '/a'), agent(105, 'session', '/b')]);
  const fold = screen.getByText('Your sessions (2)').closest('details')!;
  expect(fold.open, 'because the owner\'s own sessions are not flow\'s work, so they start folded').toBe(false);
  expect(screen.getByRole('article', { name: 'Run 100' }), 'because a flow run is a card of its own').not.toBeNull();
});

test('AgentWithASession_OpenSessionSendsItsPidAndSaysEnterWaits', async () => {
  const posted = await renderAgents([{ ...agent(100, 'agent', '/p-wt/wt-3'), session: SESSION }]);
  const button = screen.getByRole('button', { name: 'Open session' });
  expect(button.getAttribute('title'), 'because a live run cannot be resumed yet, so the command waits for Enter').toBe(OPEN_SESSION_LIVE);
  await act(async () => { fireEvent.click(button); });
  expect(posted, 'because the daemon finds the session by the pid and opens it in that folder').toEqual([{ kind: 'terminal.open', args: { path: '/p-wt/wt-3', session: '100' } }]);
  expect(screen.getAllByRole('button', { name: 'Open in Terminal' }).length, 'because a plain shell at the folder stays next to it').toBe(1);
});

test('AgentWithoutASession_NoOpenSession', async () => {
  await renderAgents([agent(100, 'agent', '/p-wt/wt-3')]);
  expect(screen.queryByRole('button', { name: 'Open session' }), 'because no transcript was found, so there is nothing to resume').toBeNull();
});

test('EndedAgent_OpenSessionSaysItResumes', async () => {
  await renderAgents([], [{ ...agent(200, 'agent', '/p-wt/wt-3'), session: SESSION, endedAt: '2026-10-24T18:10:00Z' }]);
  const table = screen.getByRole('table', { name: 'Ended agents and sessions' });
  expect(within(table).getByRole('button', { name: 'Open session' }).getAttribute('title'), 'because the run is over, so the session resumes at once').toBe(OPEN_SESSION_ENDED);
});

test('LiveRun_ShowsItsStepAndOpensItsTranscript', async () => {
  const daemon = new FakeDaemon();
  transcriptAt(daemon, 12);
  const run: Run = { item: 'gh#9', step: 'verify', profile: 'default', worktree: 'wt-3', host: 'claude', startedAt: TAKEN_AT, pid: null, liveness: 'alive' };
  await renderSnapshot({ agents: [{ ...agent(100, 'agent', '/p-wt/wt-3'), worktree: 'wt-3', item: 'gh#9', session: SESSION }], runs: [run] }, daemon);
  const card = screen.getByRole('article', { name: 'Run 100' });
  expect(card.textContent, 'because the card says which step of which item runs').toMatch(/verify · gh#9/);
  expect(within(card).getByRole('list', { name: 'Transcript of pid 100' }).textContent, 'because a live run shows its transcript without a click').toMatch(/tool.*Bash · npm test.*say.*Running the gates\./);
  expect(card.textContent, 'because the card says how far the transcript has got').toMatch(/1\.29 MB · 212 turns/);
});

test('FullLog_ReadsTheWholeTranscript', async () => {
  const daemon = new FakeDaemon();
  transcriptAt(daemon, 12);
  transcriptAt(daemon, 2000);
  const run: Run = { item: 'gh#9', step: 'verify', profile: 'default', worktree: 'wt-3', host: 'claude', startedAt: TAKEN_AT, pid: null, liveness: 'alive' };
  await renderSnapshot({ agents: [{ ...agent(100, 'agent', '/p-wt/wt-3'), worktree: 'wt-3', item: 'gh#9', session: SESSION }], runs: [run] }, daemon);
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Full log' })); });
  expect(screen.getByRole('button', { name: 'Last lines' }).getAttribute('aria-pressed'), 'because the full log is a mode of the card the owner can leave').toBe('true');
  expect(screen.getByRole('list', { name: 'Transcript of pid 100' }).closest('.run-stream')!.className, 'because the whole transcript scrolls in the card').toMatch(/full/);
});

test('StopThisRun_NamesTheItemAndSaysWhatStays', async () => {
  const run: Run = { item: 'gh#9', step: 'verify', profile: 'default', worktree: 'wt-3', host: 'claude', startedAt: TAKEN_AT, pid: null, liveness: 'alive' };
  const posted = await renderSnapshot({ agents: [{ ...agent(100, 'agent', '/p-wt/wt-3'), worktree: 'wt-3', item: 'gh#9' }], runs: [run] });
  const stop = screen.getByRole('button', { name: 'Stop this run' });
  expect(stop.getAttribute('title'), 'because the owner must know the worktree survives').toBe(STOP_HELP);
  await act(async () => { fireEvent.click(stop); });
  expect(posted, 'because flow stops the run of that item').toEqual([{ kind: 'run.stop', args: { item: 'gh#9' } }]);
});

test('RunRecordWithoutAProcess_OffersToResume', async () => {
  const run: Run = { item: 'gh#9', step: 'implement', profile: 'default', worktree: 'wt-3', host: 'claude', startedAt: TAKEN_AT, pid: null, liveness: 'dead' };
  const posted = await renderSnapshot({ runs: [run] });
  const card = screen.getByRole('article', { name: 'Run record for gh#9' });
  expect(card.textContent, 'because a dead record is a warning, not a failure, and says what Resume does').toMatch(/record, no process.*starts implement again in wt-3/);
  await act(async () => { fireEvent.click(within(card).getByRole('button', { name: 'Resume' })); });
  expect(posted, 'because flow clears the record and resumes the step where it stopped').toEqual([{ kind: 'run.resume', args: { item: 'gh#9' } }]);
});

/** The process list on the day of the false dead run: ps timed out, so nothing is known about any process. */
const PS_TIMED_OUT: Snapshot['processList'] = { status: 'unavailable', reason: 'ps timed out after 10s', lookup: { command: 'ps', code: null, timedOut: true, durationMs: 10004, stderr: '' } };

test('RunWhoseProcessIsUnknown_SaysTheProcessListIsUnavailable', async () => {
  const run: Run = { item: 'gh#9', step: 'implement', profile: 'default', worktree: 'wt-3', host: 'claude', startedAt: TAKEN_AT, pid: 19487, liveness: 'unknown' };
  await renderSnapshot({ runs: [run], processList: PS_TIMED_OUT });
  expect(screen.getByRole('article', { name: 'Run record for gh#9' }).textContent, 'because a failed lookup is said as one, never as a run that ended').toMatch(/process list unavailable: ps timed out after 10s/);
});

test('RunWhoseProcessIsUnknown_OffersNoResume', async () => {
  const run: Run = { item: 'gh#9', step: 'implement', profile: 'default', worktree: 'wt-3', host: 'claude', startedAt: TAKEN_AT, pid: 19487, liveness: 'unknown' };
  await renderSnapshot({ runs: [run], processList: PS_TIMED_OUT });
  expect(screen.queryByRole('button', { name: 'Resume' }), 'because flow refuses to resume a run that is still alive, as it did on task 33').toBeNull();
});

test('RunStillStarting_OffersNoResume', async () => {
  const run: Run = { item: 'gh#9', step: 'implement', profile: 'default', worktree: 'wt-3', host: 'claude', startedAt: TAKEN_AT, pid: null, liveness: 'starting' };
  await renderSnapshot({ runs: [run] });
  expect([screen.getByRole('article', { name: 'Run record for gh#9' }).textContent?.includes('starting'), screen.queryByRole('button', { name: 'Resume' })], 'because a run within the health job\'s grace has not had time to show its process').toEqual([true, null]);
});

test('Runs_OnlyTheFirstCardStartsOpen', async () => {
  const daemon = new FakeDaemon();
  transcriptAt(daemon, 12);
  const runs: Run[] = [9, 10].map((n) => ({ item: `gh#${n}`, step: 'verify', profile: 'default', worktree: `wt-${n}`, host: 'claude', startedAt: TAKEN_AT, pid: null, liveness: 'alive' }));
  await renderSnapshot({ agents: [{ ...agent(100, 'agent', '/p-wt/wt-9'), worktree: 'wt-9', item: 'gh#9' }, { ...agent(101, 'agent', '/p-wt/wt-10'), worktree: 'wt-10', item: 'gh#10' }], runs }, daemon);
  expect(screen.getByRole('button', { name: 'Fold run 100' }).getAttribute('aria-expanded'), 'because the first run shows its transcript').toBe('true');
  expect(screen.queryByRole('list', { name: 'Transcript of pid 101' }), 'because the rest stay folded, so the list stays short').toBeNull();
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Open run 101' })); });
  expect(screen.getByRole('button', { name: 'Fold run 101' }), 'because the owner opens the one they want').not.toBeNull();
});
