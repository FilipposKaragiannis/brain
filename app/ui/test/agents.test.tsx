import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import type { Agent, Job } from '../../daemon/src/snapshot.ts';
import { Agents } from '../src/screens/Agents.tsx';
import { FakeDaemon, HTTP_ACCEPTED, actionRecord, snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

afterEach(cleanup);

const ACTIONS_PATH = '/api/projects/project/actions';

function agent(pid: number, kind: Agent['kind'], cwd: string): Agent {
  return { pid, host: 'claude', kind, cwd, worktree: null, item: null, elapsedSeconds: 60, command: `claude ${pid}` };
}

const JOB: Job = { name: 'next', state: 'scheduled', schedule: 'every 30m', args: '', installed: true, loaded: true, paused: false, running: [], last: null, next: '18:30', runsThisWeek: 0, failedThisWeek: 0 };

async function renderAgents(agents: Agent[], jobs: Job[]): Promise<unknown[]> {
  const daemon = new FakeDaemon();
  const posted: unknown[] = [];
  daemon.answer('POST', ACTIONS_PATH, (body) => { posted.push(body); return { status: HTTP_ACCEPTED, body: { action: { ...actionRecord('t1', 'running', {}), kind: 'terminal.open', args: (body as { args: Record<string, string> }).args } } }; });
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><Agents snapshot={{ ...snapshotAt(TAKEN_AT, 0), agents, jobs }} /></Wrapper>);
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
