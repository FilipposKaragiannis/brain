import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import { PANE_CLOSE } from '../../daemon/src/paneProtocol.ts';
import type { PaneTarget } from '../../daemon/src/paneProtocol.ts';
import { OPEN_IN_TERMINAL, PaneButton, TerminalButton } from '../src/PaneControls.tsx';
import { PANE_DOCK_NAME, PaneDock } from '../src/PaneDock.tsx';
import { PANE_END_WORDS } from '../src/panes.ts';
import { FakeDaemon } from './fakeDaemon.tsx';
import type { FakeSocket } from './fakeDaemon.tsx';

afterEach(cleanup);

const FOLDER = '/work/foosbrawl';
const CLOSE_TAB = /^Close /;

function renderDock(daemon: FakeDaemon): void {
  const Wrapper = daemon.wrapper();
  render(<Wrapper><TerminalButton projectId="foosbrawl" folder={FOLDER} /><PaneDock projectOnScreen="foosbrawl" projects={[]} /></Wrapper>);
}

/** A shell pane the daemon started, shown in the dock. */
function livePane(): FakeSocket {
  const daemon = new FakeDaemon();
  renderDock(daemon);
  act(() => { fireEvent.click(screen.getByRole('button', { name: OPEN_IN_TERMINAL })); });
  const socket = daemon.sockets[0]!;
  act(() => { socket.receive({ type: 'started', pane: 'pane-1', command: ['/bin/zsh', '-l'], folder: FOLDER }); });
  return socket;
}

function endedByDaemon(): void {
  const socket = livePane();
  act(() => {
    socket.receive({ type: 'exit', code: 0, signal: null });
    socket.closeFromDaemon(PANE_CLOSE.ended);
  });
}

test('NoPane_NoDock', () => {
  renderDock(new FakeDaemon());
  expect(screen.queryByRole('region', { name: PANE_DOCK_NAME }), 'because an empty dock would only take room from the screen').toBeNull();
});

test('CloseOnATab_ClosesTheSocket', () => {
  const socket = livePane();
  act(() => { fireEvent.click(screen.getByRole('button', { name: CLOSE_TAB })); });
  expect(socket.closedWith, 'because Close ends the process on the daemon, not only the tab').toBe(PANE_CLOSE.ended);
});

test('CloseOnATab_DropsTheTab', () => {
  livePane();
  act(() => { fireEvent.click(screen.getByRole('button', { name: CLOSE_TAB })); });
  expect(screen.queryByRole('button', { name: CLOSE_TAB }), 'because a closed pane leaves the dock').toBeNull();
});

test('DaemonEndedThePane_SaysSessionEnded', () => {
  endedByDaemon();
  expect(screen.getByRole('status').textContent, 'because the owner must see the process is gone while the screen stays').toMatch(PANE_END_WORDS.sessionEnded);
});

test('DaemonEndedThePane_KeepsItsTab', () => {
  endedByDaemon();
  expect(screen.queryByRole('button', { name: CLOSE_TAB }), 'because the scrollback stays readable until the owner closes the tab').not.toBeNull();
});

/** Two shell panes, the newer in front; the owner picks the older tab again and gets its name. */
function chooseTheOlderTab(): string {
  const daemon = new FakeDaemon();
  renderDock(daemon);
  act(() => { fireEvent.click(screen.getByRole('button', { name: OPEN_IN_TERMINAL })); });
  act(() => { fireEvent.click(screen.getByRole('button', { name: OPEN_IN_TERMINAL })); });
  const olderTab = screen.getByRole('button', { pressed: false });
  act(() => { fireEvent.click(olderTab); });
  return olderTab.textContent ?? '';
}

test('ChooseAnOlderTab_OnlyItsScreenShown', () => {
  const chosen = chooseTheOlderTab();
  const shownScreens = screen.getAllByRole('region').map((region) => region.getAttribute('aria-label'));
  expect(shownScreens, 'because the dock shows the pane the owner picked and hides the newer one').toEqual([PANE_DOCK_NAME, chosen]);
});

test('ChooseAnOlderTab_ItIsTheCurrentTab', () => {
  const chosen = chooseTheOlderTab();
  const currentTabs = screen.getAllByRole('button', { pressed: true }).map((tab) => tab.textContent);
  expect(currentTabs, 'because exactly one tab marks the pane in front, and it is the one picked').toEqual([chosen]);
});

/** Opens one pane on a target through the button the screens use, and returns its tab's name. */
function tabNameFor(target: PaneTarget): string {
  const daemon = new FakeDaemon();
  const Wrapper = daemon.wrapper();
  render(<Wrapper><PaneButton projectId="foosbrawl" target={target} label="Open" title="Opens a pane" primary={false} /><PaneDock projectOnScreen="foosbrawl" projects={[]} /></Wrapper>);
  act(() => { fireEvent.click(screen.getByRole('button', { name: 'Open' })); });
  return screen.getByRole('button', { pressed: true }).textContent ?? '';
}

const TAB_NAMES: { what: string; target: PaneTarget; names: string }[] = [
  { what: 'a shell', target: { run: 'shell', folder: '/work/foosbrawl-wt/wt-4' }, names: 'wt-4' },
  { what: 'a job\'s log', target: { run: 'job', job: 'next-nightly-2' }, names: 'next-nightly-2' },
  { what: 'a session by its pid', target: { run: 'session', folder: '/work/foosbrawl-wt/wt-6', pid: 4242 }, names: 'wt-6' },
  { what: 'a gate\'s session', target: { run: 'gate', item: 'gh#731' }, names: 'gh#731' },
];

test.each(TAB_NAMES)('PaneOpened_TabNamesWhatItHolds ($what)', ({ target, names }) => {
  expect(tabNameFor(target), 'because the owner picks a tab by the folder, job or item it holds').toContain(names);
});

test('ShellAndSessionInOneFolder_TabsTellThemApart', () => {
  const daemon = new FakeDaemon();
  const Wrapper = daemon.wrapper();
  render(
    <Wrapper>
      <PaneButton projectId="foosbrawl" target={{ run: 'shell', folder: FOLDER }} label="Shell" title="Opens a shell" primary={false} />
      <PaneButton projectId="foosbrawl" target={{ run: 'session', folder: FOLDER, pid: 4242 }} label="Session" title="Opens a session" primary={false} />
      <PaneDock projectOnScreen="foosbrawl" projects={[]} />
    </Wrapper>,
  );
  act(() => { fireEvent.click(screen.getByRole('button', { name: 'Shell' })); });
  act(() => { fireEvent.click(screen.getByRole('button', { name: 'Session' })); });
  const tabs = [...screen.getAllByRole('button', { pressed: true }), ...screen.getAllByRole('button', { pressed: false })];
  const tabNames = new Set(tabs.map((tab) => tab.textContent));
  expect(tabNames.size, 'because a shell and a resumed session in the same folder are different panes the owner must tell apart').toBe(2);
});

/** Whether a wheel over the element was left to the page: false when the dock kept it. */
function wheelReachesThePage(target: Element): boolean {
  return fireEvent.wheel(target, { deltaY: 120 });
}

test('WheelOverAPane_DoesNotScrollThePage', () => {
  livePane();
  const paneScreen = screen.getAllByRole('region').find((region) => region.getAttribute('aria-label') !== PANE_DOCK_NAME)!;
  expect(wheelReachesThePage(paneScreen), 'because at the edge of the scrollback the page behind must not scroll in its place').toBe(false);
});

test('WheelOverThePageOutsideTheDock_StillScrollsThePage', () => {
  livePane();
  expect(wheelReachesThePage(screen.getByRole('button', { name: OPEN_IN_TERMINAL })), 'because only the pane keeps the wheel; the rest of the page scrolls as before').toBe(true);
});
