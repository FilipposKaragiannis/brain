import { act, cleanup, fireEvent, render, screen } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import type { PaneControl, PaneSize } from '../../daemon/src/paneProtocol.ts';
import { OPEN_IN_TERMINAL, TerminalButton } from '../src/PaneControls.tsx';
import { PaneDock } from '../src/PaneDock.tsx';
import { PANE_DOCK_RESIZE, PANE_HEIGHT } from '../src/PaneResize.tsx';
import { FakeDaemon } from './fakeDaemon.tsx';
import type { FakeSocket, FakeTerminal } from './fakeDaemon.tsx';

afterEach(() => {
  cleanup();
  try { window.localStorage.clear(); } catch { /* storage blocked: nothing kept to clear */ }
});

const FOLDER = '/work/foosbrawl';
/** Far enough to cross either bound from any height the window allows. */
const FAR_PIXELS = 5000;
/** A drag that a wrong sign or a dropped start offset would visibly miss. */
const DRAG_PIXELS = 137;

type OpenDock = { daemon: FakeDaemon; socket: FakeSocket; terminal: FakeTerminal };

/** A shell pane the daemon started, shown in the open dock. */
function openDock(): OpenDock {
  const daemon = new FakeDaemon();
  const Wrapper = daemon.wrapper();
  render(<Wrapper><TerminalButton projectId="foosbrawl" folder={FOLDER} /><PaneDock projectOnScreen="foosbrawl" projects={[]} /></Wrapper>);
  act(() => { fireEvent.click(screen.getByRole('button', { name: OPEN_IN_TERMINAL })); });
  const socket = daemon.sockets[0]!;
  act(() => { socket.receive({ type: 'started', pane: 'pane-1', command: ['/bin/zsh', '-l'], folder: FOLDER }); });
  return { daemon, socket, terminal: daemon.terminals[0]! };
}

function topEdge(): HTMLElement {
  return screen.getByRole('separator', { name: PANE_DOCK_RESIZE });
}

/** The dock's height as the edge reports it to the owner and to assistive tech. */
function dockHeight(): number {
  return Number(topEdge().getAttribute('aria-valuenow'));
}

/** Drags the top edge by `pixels`: up is positive, as the pointer moves toward the top of the window. */
function dragUp(pixels: number): void {
  const startY = 600;
  act(() => { fireEvent.pointerDown(topEdge(), { button: 0, clientY: startY }); });
  act(() => { fireEvent.pointerMove(window, { clientY: startY - pixels }); });
  act(() => { fireEvent.pointerUp(window, { clientY: startY - pixels }); });
}

function press(key: string): void {
  act(() => { fireEvent.keyDown(topEdge(), { key }); });
}

function largestHeight(): number {
  return Math.round(window.innerHeight * PANE_HEIGHT.maximumWindowShare);
}

test('DragTheTopEdgeUp_DockTallerByTheDrag', () => {
  openDock();
  const before = dockHeight();
  dragUp(DRAG_PIXELS);
  expect(dockHeight(), 'because the edge follows the pointer, so the dock grows by as much as it was dragged').toBe(before + DRAG_PIXELS);
});

test('DragTheTopEdgeDown_DockShorterByTheDrag', () => {
  openDock();
  const before = dockHeight();
  dragUp(-DRAG_PIXELS);
  expect(dockHeight(), 'because dragging the edge down gives the room back to the page').toBe(before - DRAG_PIXELS);
});

test('DragEnded_LaterPointerMoves_LeaveTheHeight', () => {
  openDock();
  dragUp(DRAG_PIXELS);
  const dropped = dockHeight();
  act(() => { fireEvent.pointerMove(window, { clientY: 10 }); });
  expect(dockHeight(), 'because once the button is up the dock stays where the owner left it').toBe(dropped);
});

test.each([
  { how: 'up', pixels: FAR_PIXELS, bound: 'the largest share of the window', expected: largestHeight },
  { how: 'down', pixels: -FAR_PIXELS, bound: 'the smallest height', expected: () => PANE_HEIGHT.minimumPixels },
])('DragTheTopEdgeFar_HeightStopsAtItsBound ($how)', ({ pixels, bound, expected }) => {
  openDock();
  dragUp(pixels);
  expect(dockHeight(), `because the dock stops at ${bound}, so neither the page nor the terminal disappears`).toBe(expected());
});

test.each([
  { key: 'ArrowUp', sign: 1 },
  { key: 'ArrowDown', sign: -1 },
])('FocusedTopEdgeArrowKey_HeightMovesOneStep ($key)', ({ key, sign }) => {
  openDock();
  const before = dockHeight();
  press(key);
  expect(dockHeight(), 'because the edge resizes from the keyboard too, one step per press').toBe(before + sign * PANE_HEIGHT.keyStepPixels);
});

/** The size of each resize the page sent the daemon, in order. */
function resizesSent(socket: FakeSocket): PaneSize[] {
  return socket.sent
    .filter((frame): frame is string => typeof frame === 'string')
    .map((frame) => JSON.parse(frame) as PaneControl)
    .filter((control) => control.type === 'resize')
    .map((control) => ({ columns: control.cols, rows: control.rows }));
}

test('DockResized_TheTerminalRefitsAndTheDaemonHearsTheNewSize', () => {
  const { socket, terminal } = openDock();
  const taller: PaneSize = { columns: terminal.size.columns, rows: terminal.size.rows + 9 };
  terminal.size = taller;
  dragUp(DRAG_PIXELS);
  expect(resizesSent(socket).at(-1), 'because the process must lay itself out at the rows the taller dock now shows').toEqual(taller);
});

test('HeightChosen_NextLoad_StartsAtIt', () => {
  openDock();
  dragUp(DRAG_PIXELS);
  const chosen = dockHeight();
  cleanup();
  openDock();
  expect(dockHeight(), 'because the owner sizes the dock once, not on every visit').toBe(chosen);
});
