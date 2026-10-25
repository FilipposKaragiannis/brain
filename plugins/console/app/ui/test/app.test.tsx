import { act, cleanup, render, screen } from '@testing-library/react';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import { App, PROJECTS_RETRY_MS } from '../src/App.tsx';
import { ClockProvider } from '../src/clock.tsx';
import { FakeDaemon, HTTP_OK, HTTP_UNAUTHORIZED } from './fakeDaemon.tsx';

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
  terminal: { value: null, from: 'default', installed: ['iterm'] },
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
