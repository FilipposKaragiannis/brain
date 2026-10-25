import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import type { Agent, EndedAgent, Job, SessionRef } from '../../daemon/src/snapshot.ts';
import { Agents } from '../src/screens/Agents.tsx';
import { OPEN_SESSION_ENDED, OPEN_SESSION_LIVE } from '../src/ui.tsx';
import { FakeDaemon, HTTP_ACCEPTED, HTTP_OK, actionRecord, snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

afterEach(cleanup);

const ACTIONS_PATH = '/api/projects/project/actions';

function agent(pid: number, kind: Agent['kind'], cwd: string): Agent {
  return { pid, host: 'claude', kind, cwd, worktree: null, item: null, elapsedSeconds: 60, command: `claude ${pid}`, session: null };
}

const JOB: Job = { name: 'next', state: 'scheduled', schedule: 'every 30m', args: '', installed: true, loaded: true, paused: false, running: [], last: null, next: '18:30', runsThisWeek: 0, failedThisWeek: 0 };

const SESSION: SessionRef = { host: 'claude', id: '8f3c', transcript: '/h/.claude/projects/-p-wt-wt-3/8f3c.jsonl', resume: ['claude', '--resume', '8f3c'] };

async function renderAgents(agents: Agent[], jobs: Job[], ended: EndedAgent[] = [], daemon = new FakeDaemon()): Promise<unknown[]> {
  const posted: unknown[] = [];
  daemon.answer('POST', ACTIONS_PATH, (body) => { posted.push(body); return { status: HTTP_ACCEPTED, body: { action: { ...actionRecord('t1', 'running', {}), kind: 'terminal.open', args: (body as { args: Record<string, string> }).args } } }; });
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><Agents snapshot={{ ...snapshotAt(TAKEN_AT, 0), agents, jobs, ended }} /></Wrapper>);
  await act(async () => {});
  return posted;
}

test('AgentsScreen_AgentAndSessionRows_EachOpenTheirOwnFolder', async () => {
  const posted = await renderAgents([agent(100, 'agent', '/p-wt/wt-3'), agent(104, 'session', '/p-wt/wt-2/src')], []);
  const row = screen.getByRole('row', { name: /104/ });
  await act(async () => { fireEvent.click(within(row).getByRole('button', { name: 'Open in Terminal' })); });
  expect(screen.getAllByRole('button', { name: /Open in Terminal/ }).length, 'because an agent row and a session row each get the button').toBe(2);
  expect(posted, 'because the terminal opens where that process works').toEqual([{ kind: 'terminal.open', args: { path: '/p-wt/wt-2/src' } }]);
});

test('AgentsScreen_JobRow_OpensTheRootFollowingTheJobsLog', async () => {
  const posted = await renderAgents([], [JOB]);
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Open in Terminal' })); });
  expect(posted, 'because a job has no folder of its own: it opens the project root and follows its log').toEqual([{ kind: 'terminal.open', args: { path: '/p', job: 'next' } }]);
});

test('AgentWithASession_OpenSessionSendsItsPidAndSaysEnterWaits', async () => {
  const posted = await renderAgents([{ ...agent(100, 'agent', '/p-wt/wt-3'), session: SESSION }], []);
  const button = screen.getByRole('button', { name: 'Open session' });
  expect(button.getAttribute('title'), 'because a live run cannot be resumed yet, so the command waits for Enter').toBe(OPEN_SESSION_LIVE);
  await act(async () => { fireEvent.click(button); });
  expect(posted, 'because the daemon finds the session by the pid and opens it in that folder').toEqual([{ kind: 'terminal.open', args: { path: '/p-wt/wt-3', session: '100' } }]);
  expect(screen.getAllByRole('button', { name: 'Open in Terminal' }).length, 'because a plain shell at the folder stays next to it').toBe(1);
});

test('AgentWithoutASession_NoOpenSession', async () => {
  await renderAgents([agent(100, 'agent', '/p-wt/wt-3')], []);
  expect(screen.queryByRole('button', { name: 'Open session' }), 'because no transcript was found, so there is nothing to resume').toBeNull();
});

test('EndedAgent_OpenSessionSaysItResumes', async () => {
  await renderAgents([], [], [{ ...agent(200, 'agent', '/p-wt/wt-3'), session: SESSION, endedAt: '2026-10-24T18:10:00Z' }]);
  const table = screen.getByRole('table', { name: 'Ended agents and sessions' });
  expect(within(table).getByRole('button', { name: 'Open session' }).getAttribute('title'), 'because the run is over, so the session resumes at once').toBe(OPEN_SESSION_ENDED);
});

test('AgentTranscript_OpenedShowsTheLastTurns', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', '/api/projects/project/agents/100/transcript?lines=20', () => ({ status: HTTP_OK, body: { turns: [{ at: TAKEN_AT, role: 'user', text: '/flow:next gh#9' }, { at: TAKEN_AT, role: 'assistant', text: 'Writing the test first.' }] } }));
  await renderAgents([{ ...agent(100, 'agent', '/p-wt/wt-3'), session: SESSION }], [], [], daemon);
  const fold = screen.getByText('Transcript').closest('details')!;
  await act(async () => { fold.open = true; fireEvent(fold, new Event('toggle')); });
  expect(screen.getByRole('list', { name: 'Transcript of pid 100' }).textContent, 'because the fold shows where the run is, in its own words').toMatch(/flow:next gh#9.*Writing the test first\./);
});
