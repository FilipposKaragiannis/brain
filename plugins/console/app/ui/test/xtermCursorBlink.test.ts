import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import type { ItermLook } from '../../daemon/src/terminalProtocol.ts';
import type { TerminalLike } from '../src/panes.ts';
import { CONSOLE_STYLE } from '../src/terminalStyle.ts';
import { xtermTerminals } from '../src/xterm.ts';

const BLINKING_ITERM: ItermLook = { fontSize: null, colours: {}, cursorStyle: 'block', cursorBlink: true, boldIsBright: true };
const STEADY_ITERM: ItermLook = { ...BLINKING_ITERM, cursorBlink: false };

/** What the shell's `cnorm` sends for `xterm-256color` at a zsh prompt: stop the cursor blinking, then show it. */
const SHELL_CURSOR_NORMAL = '\x1b[?12l\x1b[?25h';

/** Start the cursor blinking, then show it. */
const SHELL_CURSOR_BLINKING = '\x1b[?12h\x1b[?25h';

/** Stop the cursor blinking and hide it in one sequence. */
const SHELL_HIDES_A_STEADY_CURSOR = '\x1b[?12;25l';

/** Stop the cursor blinking and hide it in one sequence, then show it again. */
const SHELL_SHOWS_A_STEADY_CURSOR_AGAIN = `${SHELL_HIDES_A_STEADY_CURSOR}\x1b[?25h`;

const BLINKING_CURSOR = '.xterm-cursor.xterm-cursor-blink';
const STEADY_CURSOR = '.xterm-cursor:not(.xterm-cursor-blink)';
const ANY_CURSOR = '.xterm-cursor';
const DRAWN_ROW = '.xterm-rows > div';

const textEncoder = new TextEncoder();

/** jsdom has no media queries; xterm.js asks one for the pixel ratio, so the page answers that none matches. */
function stillMediaQuery(query: string): MediaQueryList {
  return { matches: false, media: query, onchange: null, addListener: () => {}, removeListener: () => {}, addEventListener: () => {}, removeEventListener: () => {}, dispatchEvent: () => false };
}

/** Writes the text to the terminal and settles once the next frame has drawn it. */
function drawn(terminal: TerminalLike, text: string): Promise<void> {
  return new Promise((resolve) => terminal.write(textEncoder.encode(text), () => requestAnimationFrame(() => resolve())));
}

let container: HTMLElement;
let terminal: TerminalLike | undefined;

beforeEach(() => {
  vi.stubGlobal('matchMedia', stillMediaQuery);
  container = document.createElement('div');
  document.body.append(container);
});

afterEach(() => {
  terminal?.dispose();
  terminal = undefined;
  container.remove();
  vi.unstubAllGlobals();
});

test('ShellStopsTheCursorBlinking_PaneCursorKeepsTheItermProfileBlink', async () => {
  terminal = xtermTerminals({ iterm: BLINKING_ITERM, servedFont: false })();
  terminal.showIn(container);
  terminal.focus();

  await drawn(terminal, SHELL_CURSOR_NORMAL);

  expect(container.querySelector(BLINKING_CURSOR), 'iTerm ignores CSI ? 12 l, so a pane with a blinking profile keeps its cursor blinking').not.toBeNull();
});

test('ShellStartsTheCursorBlinking_PaneCursorStaysSteadyAsTheItermProfileSays', async () => {
  terminal = xtermTerminals({ iterm: STEADY_ITERM, servedFont: false })();
  terminal.showIn(container);
  terminal.focus();

  await drawn(terminal, SHELL_CURSOR_BLINKING);

  expect(container.querySelector(STEADY_CURSOR), 'iTerm ignores CSI ? 12 h, so a pane with a steady profile keeps its cursor steady').not.toBeNull();
});

test('ShellHidesTheCursorAlongsideTheBlinkMode_PaneCursorIsHidden', async () => {
  terminal = xtermTerminals({ iterm: BLINKING_ITERM, servedFont: false })();
  terminal.showIn(container);
  terminal.focus();

  await drawn(terminal, SHELL_HIDES_A_STEADY_CURSOR);

  expect(container.querySelector(DRAWN_ROW), 'the pane must have drawn its rows for a missing cursor to mean a hidden one').not.toBeNull();
  expect(container.querySelector(ANY_CURSOR), 'dropping mode 12 from CSI ? 12 ; 25 l still applies mode 25, which hides the cursor').toBeNull();
});

test('ShellStopsTheBlinkAlongsideOtherModes_PaneCursorKeepsTheItermProfileBlink', async () => {
  terminal = xtermTerminals({ iterm: BLINKING_ITERM, servedFont: false })();
  terminal.showIn(container);
  terminal.focus();

  await drawn(terminal, SHELL_SHOWS_A_STEADY_CURSOR_AGAIN);

  expect(container.querySelector(BLINKING_CURSOR), 'mode 12 carried with other modes is ignored as iTerm ignores it, so the profile blink stays').not.toBeNull();
});

test('ShellStartsTheCursorBlinkingWithoutAnItermProfile_PaneCursorBlinks', async () => {
  terminal = xtermTerminals(CONSOLE_STYLE)();
  terminal.showIn(container);
  terminal.focus();

  await drawn(terminal, SHELL_CURSOR_BLINKING);

  expect(container.querySelector(BLINKING_CURSOR), 'without an iTerm profile the pane obeys mode 12 as xterm does').not.toBeNull();
});
