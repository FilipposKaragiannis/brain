import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import type { ActionRecord, Agent, EndedAgent, Job, Run, Server, SessionRef, Snapshot } from '../../daemon/src/snapshot.ts';
import { Agents, STOP_HELP, STOP_SESSION_HELP } from '../src/screens/Agents.tsx';
import { OPEN_SESSION_ENDED, OPEN_SESSION_LIVE } from '../src/ui.tsx';
import { WORDS } from '../src/words.ts';
import { FakeDaemon, HTTP_ACCEPTED, HTTP_OK, actionRecord, snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

afterEach(cleanup);

const ACTIONS_PATH = '/api/projects/project/actions';

function agent(pid: number, kind: Agent['kind'], cwd: string): Agent {
  return { pid, host: 'claude', kind, cwd, worktree: null, item: null, step: null, job: null, elapsedSeconds: 60, startedAt: '2026-10-24T18:15:04Z', command: `claude ${pid}`, session: null, activity: null, subagents: [] };
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
});

test('RunWithASession_NoOpenInTerminal', async () => {
  await renderAgents([{ ...agent(100, 'agent', '/p-wt/wt-3'), session: SESSION }]);
  expect(within(screen.getByRole('article', { name: 'Run 100' })).queryByRole('button', { name: 'Open in Terminal' }), 'because Open session opens a terminal in the same folder, so one button does').toBeNull();
});

test('OwnSessionWithASession_NoOpenInTerminal', async () => {
  await renderAgents([{ ...agent(104, 'session', '/p-wt/wt-2'), session: SESSION }]);
  const row = screen.getByRole('listitem', { name: 'Session 104' });
  expect([within(row).queryByRole('button', { name: 'Open session' }) !== null, within(row).queryByRole('button', { name: 'Open in Terminal' })], 'because the session row opens its session and nothing beside it').toEqual([true, null]);
});

test('EndedWithASession_NoOpenInTerminal', async () => {
  await renderAgents([], [{ ...agent(200, 'agent', '/p-wt/wt-3'), session: SESSION, endedAt: '2026-10-24T18:10:00Z' }]);
  const table = screen.getByRole('table', { name: 'Ended agents and sessions' });
  expect([within(table).queryByRole('button', { name: 'Open session' }) !== null, within(table).queryByRole('button', { name: 'Open in Terminal' })], 'because resuming the ended session opens the terminal there').toEqual([true, null]);
});

test('EndedWithoutASession_KeepsOpenInTerminal', async () => {
  await renderAgents([], [{ ...agent(201, 'session', '/p-wt/wt-3'), endedAt: '2026-10-24T18:10:00Z' }]);
  const table = screen.getByRole('table', { name: 'Ended agents and sessions' });
  expect(within(table).queryByRole('button', { name: 'Open in Terminal' }), 'because with nothing to resume a plain shell at the folder is the way in').not.toBeNull();
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

test('AliveRunWithNoLocatedAgent_ShowsItsRecordWithoutResume', async () => {
  const run: Run = { item: 'gh#9', step: 'implement', profile: 'default', worktree: 'wt-3', host: 'claude', startedAt: TAKEN_AT, pid: 19487, liveness: 'alive' };
  await renderSnapshot({ runs: [run] });
  const card = screen.getByRole('article', { name: 'Run record for gh#9' });
  expect([card.textContent?.includes('alive, agent not located'), card.textContent?.includes('wt-3'), screen.queryByText(/No flow run is going/)], 'because a run whose owner still runs is going, even when its agent was not located').toEqual([true, true, null]);
  expect([screen.queryByRole('button', { name: 'Resume' }), screen.queryByRole('button', { name: /Open session/ })], 'because flow refuses to resume a live run, and there is no located session to open').toEqual([null, null]);
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

const CODEX_SESSION: SessionRef = { host: 'codex', id: '019c-wt3', transcript: '/h/.codex/sessions/2026/10/24/rollout-019c-wt3.jsonl', resume: ['codex', 'resume', '019c-wt3'] };
const CODEX_LINES = [{ at: TAKEN_AT, kind: 'tool', text: 'shell · npm test -- --grep panel' }, { at: TAKEN_AT, kind: 'say', text: 'The panel test fails; fixing the layout.' }];

/** A codex exec run of the next job, on gh#9's implement step in wt-3, with its session located. */
function codexRun(pid: number): Agent {
  return { ...agent(pid, 'agent', '/p-wt/wt-3'), host: 'codex', worktree: 'wt-3', item: 'gh#9', step: 'implement', job: 'next', session: CODEX_SESSION };
}

function codexTranscriptAt(daemon: FakeDaemon, pid: number, lines: number): void {
  daemon.answer('GET', `/api/projects/project/agents/${pid}/transcript?lines=${lines}`, () => ({ status: HTTP_OK, body: { turns: [], lines: CODEX_LINES, bytes: 4_342, turnCount: 6 } }));
}

test('CodexRun_TitleSaysItsStepAndItem', async () => {
  await renderAgents([codexRun(100)]);
  expect(screen.getByRole('article', { name: 'Run 100' }).querySelector('.run-card-title')!.textContent, 'because a codex run says what it works on as a claude run does, from its own step and item').toBe('implement · gh#9');
});

test('CodexRun_TaggedWithItsJob', async () => {
  await renderAgents([codexRun(100)]);
  expect(within(screen.getByRole('article', { name: 'Run 100' })).getByText('job next').getAttribute('title'), 'because the card says which flow job started the run, and what that means').toBe(WORDS.job);
});

test('Run_TaggedHeadless', async () => {
  await renderAgents([codexRun(100)]);
  expect(within(screen.getByRole('article', { name: 'Run 100' })).getByText('headless').getAttribute('title'), 'because no one types into a flow run, and the tag says so').toBe(WORDS.headless);
});

test('CodexRun_ShowsItsTranscript', async () => {
  const daemon = new FakeDaemon();
  codexTranscriptAt(daemon, 100, 12);
  await renderAgents([codexRun(100)], [], daemon);
  expect(screen.getByRole('list', { name: 'Transcript of pid 100' }).textContent, 'because the daemon reads a Codex session as lines too, so a codex run is followed like a claude one').toMatch(/tool.*shell · npm test -- --grep panel.*say.*The panel test fails; fixing the layout\./);
});

test('FoldedRun_ShowsItsLatestLine', async () => {
  const daemon = new FakeDaemon();
  codexTranscriptAt(daemon, 101, 1);
  await renderAgents([agent(100, 'agent', '/p-wt/wt-2'), codexRun(101)], [], daemon);
  expect(screen.getByLabelText('Latest line of run 101').textContent, 'because a folded run still says what it is doing now').toBe('sayThe panel test fails; fixing the layout.');
});

test('RunWithoutATranscript_SaysNoneWasFound', async () => {
  await renderAgents([{ ...codexRun(100), session: null }]);
  expect(screen.getByRole('article', { name: 'Run 100' }).querySelector('.stream-note')!.textContent, 'because with no session located there is nothing to read, and the card says so instead of asking').toBe('No transcript was found for this run.');
});

test('FoldedRunWithoutATranscript_ShowsNoLatestLine', async () => {
  await renderAgents([agent(100, 'agent', '/p-wt/wt-2'), { ...codexRun(101), session: null }]);
  expect(screen.queryByLabelText('Latest line of run 101'), 'because a run with no session located has no line to show, and its folded card asks for none').toBeNull();
});

test('RunStarted_IsWhenItsProcessStarted', async () => {
  const processStart = new Date(2026, 9, 24, 18, 15).toISOString();
  const run: Run = { item: 'gh#9', step: 'verify', profile: 'default', worktree: 'wt-3', host: 'claude', startedAt: new Date(2026, 9, 24, 17, 2).toISOString(), pid: null, liveness: 'alive' };
  await renderSnapshot({ agents: [{ ...agent(100, 'agent', '/p-wt/wt-3'), worktree: 'wt-3', item: 'gh#9', startedAt: processStart }], runs: [run] });
  const started = within(screen.getByRole('article', { name: 'Run 100' })).getByText('Started').nextElementSibling!;
  expect(started.textContent, "because the card says when this agent's process started, not when the run record of its worktree did").toBe('18:15');
});

const HOUR_MS = 3600 * 1000;
/** A moment `hours` before the snapshot was taken. */
const hoursBefore = (hours: number): string => new Date(Date.parse(TAKEN_AT) - hours * HOUR_MS).toISOString();

/** The interactive claude that sat in foosbrawl-wt-10, idle for three days and two hours. */
function idleSession(pid: number, idleHours: number): Agent {
  return { ...agent(pid, 'session', `/p-wt/wt-${pid}`), worktree: `wt-${pid}`, startedAt: hoursBefore(12 * 24), elapsedSeconds: 12 * 24 * 3600, activity: { status: 'idle', since: hoursBefore(idleHours) } };
}

test('IdleSession_RowSaysForHowLong', async () => {
  await renderAgents([idleSession(62102, 74)]);
  expect(screen.getByRole('listitem', { name: 'Session 62102' }).textContent, 'because the owner needs to see the session has waited on nobody for days').toContain('idle 3d 2h');
});

test('BusySession_SaysBusyAndIsNeverStale', async () => {
  await renderAgents([{ ...idleSession(62102, 74), activity: { status: 'busy', since: hoursBefore(30) } }]);
  const row = screen.getByRole('listitem', { name: 'Session 62102' });
  expect([row.textContent?.includes('busy'), within(row).queryByText('stale')], 'because a session at work is not forgotten, however long it has run').toEqual([true, null]);
});

test('SessionThatSaysNothingOfBeingIdle_ShowsHowLongItHasRun', async () => {
  await renderAgents([{ ...agent(7, 'session', '/p-wt/wt-3'), host: 'codex', elapsedSeconds: 5 * 3600 + 7 * 60, startedAt: hoursBefore(5) }]);
  expect(screen.getByRole('listitem', { name: 'Session 7' }).textContent, 'because Codex writes no status, so its age is all there is').toContain('5h 07m');
});

test('SessionIdlePastTheLimit_TaggedStale', async () => {
  await renderAgents([idleSession(62102, 25)]);
  expect(within(screen.getByRole('listitem', { name: 'Session 62102' })).queryByText('stale'), 'because idle past jobs.health.stale_session (24h here) is stale').not.toBeNull();
});

test('SessionIdleUnderTheLimit_NotStale', async () => {
  await renderAgents([idleSession(62102, 23)]);
  expect(within(screen.getByRole('listitem', { name: 'Session 62102' })).queryByText('stale'), 'because a session idle for less than the limit may just be waiting on its owner at lunch').toBeNull();
});

test('SessionWithNoStatusRunningPastTheLimit_TaggedStale', async () => {
  await renderAgents([{ ...agent(7, 'session', '/p-wt/wt-3'), host: 'codex', elapsedSeconds: 30 * 3600, startedAt: hoursBefore(30) }]);
  expect(within(screen.getByRole('listitem', { name: 'Session 7' })).queryByText('stale'), 'because with no idle signal a session is judged by how long its process has run').not.toBeNull();
});

test('StaleSession_FoldOpensWithTheCountInItsHeading', async () => {
  await renderAgents([agent(104, 'session', '/a'), idleSession(62102, 74)]);
  const fold = screen.getByText('Your sessions (2 · 1 stale)').closest('details')!;
  expect(fold.open, 'because a stale session holds up its worktree\'s PR, so the owner must not have to go looking for it').toBe(true);
});

test('StaleSession_ListedFirst', async () => {
  await renderAgents([agent(104, 'session', '/a'), idleSession(62102, 74)]);
  const rows = within(screen.getByRole('list', { name: 'Your sessions' })).getAllByRole('listitem');
  expect(rows.map((row) => row.getAttribute('aria-label')), 'because the one to deal with comes first').toEqual(['Session 62102', 'Session 104']);
});

test('StopSession_FirstPress_OnlyAsksToConfirm', async () => {
  const posted = await renderAgents([idleSession(62102, 74)]);
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Stop session' })); });
  expect([posted, screen.getByRole('group', { name: 'Confirm stopping session 62102' }).textContent], 'because one stray click must never end a session').toEqual([[], expect.stringContaining('SIGTERM to pid 62102?')]);
});

test('StopSession_Confirmed_SendsThePidAndTheStartThePageShows', async () => {
  const posted = await renderAgents([idleSession(62102, 74)]);
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Stop session' })); });
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Stop it' })); });
  expect(posted, 'because the daemon signals the pid only while it still runs the session started then').toEqual([{ kind: 'session.stop', args: { pid: '62102', startedAt: hoursBefore(12 * 24) } }]);
});

test('StopSession_Cancelled_ButtonBackAndNothingSent', async () => {
  const posted = await renderAgents([idleSession(62102, 74)]);
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Stop session' })); });
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Cancel' })); });
  expect([posted, screen.getByRole('button', { name: 'Stop session' }).getAttribute('title')], 'because Cancel disarms the stop and says nothing to the daemon').toEqual([[], STOP_SESSION_HELP]);
});

/** The Codex app server pid 64347 that works in foosbrawl-wt-10, up for two days and three hours. */
const APP_SERVER: Server = { pid: 64347, host: 'codex', label: 'Codex app server', worktree: 'foosbrawl-wt-10', startedAt: hoursBefore(51), elapsedSeconds: 51 * 3600, command: '/x/codex app-server --listen unix:///tmp/codex.sock' };

test('Servers_FoldAfterTheSessionsUnderACount', async () => {
  await renderSnapshot({ agents: [agent(104, 'session', '/a')], servers: [APP_SERVER] });
  const fold = screen.getByText('Servers (1)').closest('details')!;
  const sessions = screen.getByText('Your sessions (1)').closest('details')!;
  expect([fold.open, sessions.compareDocumentPosition(fold) & Node.DOCUMENT_POSITION_FOLLOWING], 'because the servers are only for knowing what runs, so they sit folded under the sessions').toEqual([false, Node.DOCUMENT_POSITION_FOLLOWING]);
});

test('Servers_RowShowsLabelPidWorktreeAndRunningFor', async () => {
  await renderSnapshot({ servers: [APP_SERVER] });
  const row = screen.getByRole('listitem', { name: 'Server 64347' });
  expect(['Codex app server', '64347', 'foosbrawl-wt-10', '2d 3h'].map((part) => row.textContent?.includes(part)), 'because the owner tells what runs, where and for how long from the row').toEqual([true, true, true, true]);
});

test('Servers_CommandOnHover', async () => {
  await renderSnapshot({ servers: [APP_SERVER] });
  expect(screen.getByRole('listitem', { name: 'Server 64347' }).getAttribute('title'), 'because the full command is there for whoever wants it, without crowding the row').toBe(APP_SERVER.command);
});

test('Servers_NoActions', async () => {
  await renderSnapshot({ servers: [APP_SERVER] });
  expect(within(screen.getByRole('list', { name: 'Servers' })).queryAllByRole('button'), 'because the list only says what runs; a server is never stopped or opened from here').toEqual([]);
});

test('Servers_SaysTheyAreNotSessions', async () => {
  await renderSnapshot({ servers: [APP_SERVER] });
  expect(screen.getByText(/Not sessions/).textContent, 'because a server in a worktree could pass for someone at work there').toContain('The comments and health jobs ignore them.');
});

test('Servers_None_FoldHidden', async () => {
  await renderSnapshot({ agents: [agent(104, 'session', '/a')] });
  expect(screen.queryByText(/^Servers/), 'because an empty fold says nothing, as the sessions and ended folds hide when empty').toBeNull();
});
