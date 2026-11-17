import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import { App, PROJECTS_RETRY_MS } from '../src/App.tsx';
import { ClockProvider } from '../src/clock.tsx';
import { OPEN_IN_TERMINAL } from '../src/PaneControls.tsx';
import { PANE_DOCK_NAME } from '../src/PaneDock.tsx';
import { FakeDaemon, HTTP_OK, HTTP_UNAUTHORIZED, snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

const PROJECTS_PATH = '/api/projects';
const NETWORK_DOWN = 0;
const FOOSBRAWL = { id: 'foosbrawl', name: 'foosbrawl', counts: null };

beforeEach(() => { vi.useFakeTimers(); window.location.hash = ''; });
afterEach(() => { cleanup(); vi.useRealTimers(); });

function renderApp(daemon: FakeDaemon): void {
  const Wrapper = daemon.wrapper();
  render(<Wrapper><ClockProvider clock={() => 0}><App /></ClockProvider></Wrapper>);
}

async function flush(milliseconds: number): Promise<void> {
  await act(async () => { await vi.advanceTimersByTimeAsync(milliseconds); });
}

test('ProjectsRefusedForToken_SaysATokenIsNeeded', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', PROJECTS_PATH, () => ({ status: HTTP_UNAUTHORIZED, body: { error: 'token required' } }));
  renderApp(daemon);
  await flush(0);
  expect(screen.queryByText(/token needed/i), 'because a 401 is a missing token, not an empty daemon').not.toBeNull();
});

test('DaemonNotUp_SaysNotReachable', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', PROJECTS_PATH, () => ({ status: NETWORK_DOWN, body: { error: 'fetch failed' } }));
  renderApp(daemon);
  await flush(0);
  expect(screen.queryByText(/daemon not reachable/i), 'because a daemon that is down must not read as one watching no project').not.toBeNull();
});

test('DaemonComesUp_ListedOnTheNextRetry', async () => {
  const daemon = new FakeDaemon();
  daemon.answer('GET', PROJECTS_PATH, () => ({ status: NETWORK_DOWN, body: null }));
  renderApp(daemon);
  await flush(0);
  daemon.answer('GET', PROJECTS_PATH, () => ({ status: HTTP_OK, body: [FOOSBRAWL] }));
  await flush(PROJECTS_RETRY_MS);
  expect(screen.queryByText(/daemon not reachable/i), 'because the list is read again every ten seconds until it answers').toBeNull();
});

test('UnknownProjectInHash_SaysSo', async () => {
  window.location.hash = '#/nowhere/overview';
  const daemon = new FakeDaemon();
  daemon.answer('GET', PROJECTS_PATH, () => ({ status: HTTP_OK, body: [FOOSBRAWL] }));
  renderApp(daemon);
  await flush(0);
  expect(screen.queryByText('No project nowhere.'), 'because a stale link must say the project is gone instead of waiting forever').not.toBeNull();
});

const SETTINGS_VIEW = {
  configFile: '/home/o/.config/brain-console/config.json', readFromLegacyFile: null, stateDir: '/home/o/.local/state/brain-console', launchd: false,
  projects: { roots: ['/work/projects/foosbrawl'], from: 'file', editable: true, note: null },
  port: { value: 7474, from: 'default', saved: null, note: 'The daemon listens on 7474; a new port takes a restart of the daemon.' },
};

test('App_SettingsHash_ShowsSettingsInTheShell', async () => {
  window.location.hash = '#/settings';
  const daemon = new FakeDaemon();
  daemon.answer('GET', PROJECTS_PATH, () => ({ status: HTTP_OK, body: [FOOSBRAWL] }));
  daemon.answer('GET', '/api/settings', () => ({ status: HTTP_OK, body: SETTINGS_VIEW }));
  renderApp(daemon);
  await flush(0);
  expect(screen.getByRole('heading', { level: 1 }).textContent, 'because #/settings opens the Settings screen').toBe('Settings');
  expect(window.location.hash, 'because settings need no project in the address').toBe('#/settings');
});

test('App_AnyScreen_LinksToSettingsInTheTopBar', async () => {
  window.location.hash = '#/foosbrawl/agents';
  const daemon = new FakeDaemon();
  daemon.answer('GET', PROJECTS_PATH, () => ({ status: HTTP_OK, body: [FOOSBRAWL] }));
  renderApp(daemon);
  await flush(0);
  expect(screen.getAllByRole('link', { name: 'Settings' }).length, 'because Settings is one click away from any screen').toBeGreaterThan(0);
});

test('App_ProjectsEvent_TheSwitcherListsTheNewProject', async () => {
  window.location.hash = '#/foosbrawl/overview';
  const daemon = new FakeDaemon();
  daemon.answer('GET', PROJECTS_PATH, () => ({ status: HTTP_OK, body: [FOOSBRAWL] }));
  renderApp(daemon);
  await flush(0);
  act(() => { daemon.latestStream().send('projects', [FOOSBRAWL, { id: 'brain', name: 'brain', counts: null }]); });
  expect(screen.getByRole('option', { name: 'brain' }), 'because a project added in Settings shows without a reload').not.toBeNull();
});

test('App_Nav_ListsAgentsThenJobs', async () => {
  window.location.hash = '#/foosbrawl/overview';
  const daemon = new FakeDaemon();
  daemon.answer('GET', PROJECTS_PATH, () => ({ status: HTTP_OK, body: [FOOSBRAWL] }));
  renderApp(daemon);
  await flush(0);
  const labels = within(screen.getByRole('navigation', { name: 'Main' })).getAllByRole('link').map((link) => link.textContent);
  expect(labels.slice(labels.indexOf('Agents'), labels.indexOf('Agents') + 2), 'because the runs and the jobs are two pages, the jobs right after the agents').toEqual(['Agents', 'Jobs']);
  expect(labels, 'because the old combined page is gone').not.toContain('Agents and jobs');
});

test('App_JobsHash_OpensTheJobsPage', async () => {
  window.location.hash = '#/foosbrawl/jobs';
  const daemon = new FakeDaemon();
  daemon.answer('GET', PROJECTS_PATH, () => ({ status: HTTP_OK, body: [FOOSBRAWL] }));
  renderApp(daemon);
  await flush(0);
  expect(screen.getByRole('heading', { level: 1 }).textContent, 'because #/<project>/jobs is the Jobs page').toBe('Jobs');
});

test('App_OldAgentsHash_OpensTheAgentsPage', async () => {
  window.location.hash = '#/foosbrawl/agents';
  const daemon = new FakeDaemon();
  daemon.answer('GET', PROJECTS_PATH, () => ({ status: HTTP_OK, body: [FOOSBRAWL] }));
  renderApp(daemon);
  await flush(0);
  expect(screen.getByRole('heading', { level: 1 }).textContent, 'because a link from before the split still lands on the runs').toBe('Agents');
});

test('App_JobRunning_JobsNavSaysHowMany', async () => {
  window.location.hash = '#/foosbrawl/agents';
  const daemon = new FakeDaemon();
  daemon.answer('GET', PROJECTS_PATH, () => ({ status: HTTP_OK, body: [FOOSBRAWL] }));
  renderApp(daemon);
  await flush(0);
  const snapshot = snapshotAt(TAKEN_AT, 0);
  act(() => { daemon.latestStream().send('snapshot', { ...snapshot, project: { ...snapshot.project, id: 'foosbrawl' }, counts: { ...snapshot.counts, jobsRunning: 2 } }); });
  expect(within(screen.getByRole('navigation', { name: 'Main' })).getByRole('link', { name: /^Jobs/ }).textContent, 'because the nav says when jobs run, as Agents says when agents are live').toBe('Jobs2 running');
});

const UPDATE_NOTICE = /brain-console update/;

/** The page on foosbrawl's overview once the stream sent this snapshot. */
async function renderWithSnapshot(snapshot: ReturnType<typeof snapshotAt>): Promise<void> {
  window.location.hash = '#/foosbrawl/overview';
  const daemon = new FakeDaemon();
  daemon.answer('GET', PROJECTS_PATH, () => ({ status: HTTP_OK, body: [FOOSBRAWL] }));
  renderApp(daemon);
  await flush(0);
  act(() => { daemon.latestStream().send('snapshot', snapshot); });
}

test('App_NewerConsoleInstalled_BannerNamesBothVersionsAndUpdate', async () => {
  await renderWithSnapshot({ ...snapshotAt(TAKEN_AT, 0), newerConsole: { running: '0.9.2', cached: '0.10.0' } });
  expect(screen.getByRole('status').textContent, 'because the page says which console is installed, which one runs, and how to move').toMatch(/0\.10\.0.*0\.9\.2.*brain-console update/);
});

test('App_DaemonRunsTheNewestConsole_NoBanner', async () => {
  await renderWithSnapshot(snapshotAt(TAKEN_AT, 0));
  expect(screen.queryByText(UPDATE_NOTICE), 'because the notice goes once the daemon runs the newest cached version').toBeNull();
});

test('App_Nav_LinksTheRetroPage', async () => {
  window.location.hash = '#/foosbrawl/overview';
  const daemon = new FakeDaemon();
  daemon.answer('GET', PROJECTS_PATH, () => ({ status: HTTP_OK, body: [FOOSBRAWL] }));
  renderApp(daemon);
  await flush(0);
  expect(within(screen.getByRole('navigation', { name: 'Main' })).getByRole('link', { name: 'Retro' }).getAttribute('href'), 'because the Retro page is reached from the nav like every project page').toBe('#/foosbrawl/retro');
});

const BRAIN = { id: 'brain', name: 'brain', counts: null };

/** The page on foosbrawl's overview with its snapshot, the project root at `/p`. */
async function renderFoosbrawl(daemon: FakeDaemon): Promise<void> {
  window.location.hash = '#/foosbrawl/overview';
  daemon.answer('GET', PROJECTS_PATH, () => ({ status: HTTP_OK, body: [FOOSBRAWL, BRAIN] }));
  daemon.answer('GET', '/api/settings', () => ({ status: HTTP_OK, body: SETTINGS_VIEW }));
  renderApp(daemon);
  await flush(0);
  const snapshot = snapshotAt(TAKEN_AT, 0);
  act(() => { daemon.latestStream().send('snapshot', { ...snapshot, project: { ...snapshot.project, id: 'foosbrawl' } }); });
}

function clickProjectBarTerminalPane(): void {
  const [projectBar] = screen.getAllByRole('button', { name: OPEN_IN_TERMINAL });
  if (projectBar === undefined) throw new Error('no Terminal pane button on the page');
  act(() => { fireEvent.click(projectBar); });
}

test('App_ProjectBarTerminalPane_OpensAShellAtTheProjectRoot', async () => {
  const daemon = new FakeDaemon();
  await renderFoosbrawl(daemon);
  clickProjectBarTerminalPane();
  expect(daemon.sockets.map((socket) => ({ path: socket.queryParameter('path'), run: socket.queryParameter('run') })), 'because the project bar opens a shell at the project root').toEqual([{ path: '/p', run: 'shell' }]);
});

test('App_ProjectBar_OneButtonOpensATerminalAndNoneStartsAnAgent', async () => {
  await renderFoosbrawl(new FakeDaemon());
  const projectBar = screen.getByRole('region', { name: 'Project details' }).parentElement!;
  const named = within(projectBar).getAllByRole('button').map((button) => button.textContent ?? '').filter((name) => /terminal|session|claude|codex/i.test(name));
  expect(named, 'because Open in Terminal and Terminal pane are one button, and the owner starts claude or codex by hand in it').toEqual([OPEN_IN_TERMINAL]);
});

const NAVIGATIONS = [
  { to: 'a screen change', hash: '#/foosbrawl/agents' },
  { to: 'a project switch', hash: '#/brain/overview' },
  { to: 'Settings', hash: '#/settings' },
];

async function openPaneThenGo(daemon: FakeDaemon, hash: string): Promise<void> {
  await renderFoosbrawl(daemon);
  clickProjectBarTerminalPane();
  act(() => { daemon.sockets[0]!.receive({ type: 'started', pane: 'pane-1', command: ['/bin/zsh', '-l'], folder: '/p' }); });
  act(() => { window.location.hash = hash; window.dispatchEvent(new HashChangeEvent('hashchange')); });
  await flush(0);
}

test.each(NAVIGATIONS)('App_PaneOpenThenNavigate_KeepsTheDock ($to)', async ({ hash }) => {
  await openPaneThenGo(new FakeDaemon(), hash);
  expect(screen.queryByRole('region', { name: PANE_DOCK_NAME }), 'because the dock sits outside the routed screens, so moving around the console leaves the pane open').not.toBeNull();
});

test.each(NAVIGATIONS)('App_PaneOpenThenNavigate_KeepsItsProcess ($to)', async ({ hash }) => {
  const daemon = new FakeDaemon();
  await openPaneThenGo(daemon, hash);
  expect(daemon.sockets.map((socket) => socket.closedWith), 'because moving around the console must not hang up the pane nor start a second one').toEqual([null]);
});
