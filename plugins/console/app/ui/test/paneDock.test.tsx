import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import { PANE_CLOSE } from '../../daemon/src/paneProtocol.ts';
import { PaneControls, quickSessionName, TERMINAL_PANE } from '../src/PaneControls.tsx';
import { PANE_DOCK_NAME, PaneDock } from '../src/PaneDock.tsx';
import { PANE_END_WORDS } from '../src/panes.ts';
import { FakeDaemon } from './fakeDaemon.tsx';
import type { FakeSocket } from './fakeDaemon.tsx';

afterEach(cleanup);

const FOLDER = '/work/foosbrawl';
const CLOSE_TAB = /^Close /;

function renderDock(daemon: FakeDaemon): void {
  const Wrapper = daemon.wrapper();
  render(<Wrapper><PaneControls projectId="foosbrawl" folder={FOLDER} /><PaneDock projectOnScreen="foosbrawl" projects={[]} /></Wrapper>);
}

/** A shell pane the daemon started, shown in the dock. */
function livePane(): FakeSocket {
  const daemon = new FakeDaemon();
  renderDock(daemon);
  act(() => { fireEvent.click(screen.getByRole('button', { name: TERMINAL_PANE })); });
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

/** A shell pane, then a claude pane in front of it; the owner picks the shell's tab again and gets its name. */
function chooseTheOlderTab(): string {
  const daemon = new FakeDaemon();
  renderDock(daemon);
  act(() => { fireEvent.click(screen.getByRole('button', { name: TERMINAL_PANE })); });
  act(() => { fireEvent.click(screen.getByRole('button', { name: quickSessionName('claude') })); });
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
