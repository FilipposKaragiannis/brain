import { FitAddon } from '@xterm/addon-fit';
import type { IDisposable } from '@xterm/xterm';
import { Terminal } from '@xterm/xterm';
import '@xterm/xterm/css/xterm.css';
import type { TerminalFactory } from './panes.ts';
import { paneSizeInBounds } from './panes.ts';
import type { FontInstaller, PageLook, TerminalStyle } from './terminalStyle.ts';
import { paneLook } from './terminalStyle.ts';

const utf8Encoder = new TextEncoder();

const PANE_BACKGROUND_PROPERTY = '--pane-background';

const CURSOR_BLINK_MODE = 12;
const DEC_PRIVATE_PREFIX = '?';
const SET_AND_RESET_FINALS = ['h', 'l'];

function pageLook(): PageLook {
  const style = getComputedStyle(document.documentElement);
  const read = (property: string): string => style.getPropertyValue(property).trim();
  const colours = {
    background: read('--terminal'),
    foreground: read('--terminal-ink'),
    cursor: read('--terminal-cursor'),
    cursorAccent: read('--terminal'),
    selectionBackground: read('--terminal-selection'),
  };
  return { colours, fontFamily: read('--terminal-font') };
}

/** Installs the font file as a `FontFace` of the family once the browser has loaded it, unless the signal cancelled the install first. */
export const browserFontInstaller: FontInstaller = async (family, bytes, signal) => {
  try {
    const face = new FontFace(family, bytes);
    const loaded = await Promise.race([face.load().then(() => true), whenAborted(signal)]);
    if (!loaded || signal.aborted) return false;
    document.fonts.add(face);
    return true;
  } catch {
    return false;
  }
};

function whenAborted(signal: AbortSignal): Promise<false> {
  return new Promise((resolve) => {
    if (signal.aborted) resolve(false);
    else signal.addEventListener('abort', () => resolve(false), { once: true });
  });
}

/** Paints the dock behind the panes in the iTerm profile's background, so the edge around a terminal matches it; without one the stylesheet's stays. */
export function paintPaneBackground(style: TerminalStyle): void {
  const background = style.iterm?.colours.background;
  if (background !== undefined) document.documentElement.style.setProperty(PANE_BACKGROUND_PROPERTY, background);
}

function holdsBlinkMode(modes: (number | number[])[]): boolean {
  return modes.includes(CURSOR_BLINK_MODE);
}

function isBlinkModeAlone(modes: (number | number[])[]): boolean {
  return modes.every((mode) => mode === CURSOR_BLINK_MODE);
}

function restoreBlinkOnceParsed(terminal: Terminal, profileBlink: boolean): void {
  const restore = terminal.onWriteParsed(() => {
    restore.dispose();
    terminal.options.cursorBlink = profileBlink;
  });
}

function pinCursorBlink(terminal: Terminal, profileBlink: boolean): IDisposable[] {
  const swallowBlinkModeOrRestoreProfileBlink = (modes: (number | number[])[]): boolean => {
    if (!holdsBlinkMode(modes)) return false;
    if (isBlinkModeAlone(modes)) return true;
    restoreBlinkOnceParsed(terminal, profileBlink);
    return false;
  };
  return SET_AND_RESET_FINALS.map((final) => terminal.parser.registerCsiHandler({ prefix: DEC_PRIVATE_PREFIX, final }, swallowBlinkModeOrRestoreProfileBlink));
}

/**
 * A pane's terminal on xterm.js, the one file that imports it, in the look `paneLook` gives the
 * style. The terminal lives in a host element of its own: the first `showIn` opens it there, a
 * later one only moves the host, so a second mount (StrictMode, a dock that re-renders) never
 * opens it twice. Without an iTerm profile its colours follow the page's light and dark themes.
 */
export function xtermTerminals(style: TerminalStyle): TerminalFactory {
  return () => {
    const look = paneLook(style, pageLook());
    const terminal = new Terminal({
      theme: look.colours, fontFamily: look.fontFamily, fontSize: look.fontSize,
      cursorStyle: look.cursorStyle, cursorBlink: look.cursorBlink, drawBoldTextInBrightColors: look.boldIsBright,
    });
    const fitAddon = new FitAddon();
    terminal.loadAddon(fitAddon);
    const blinkPins = style.iterm === null ? [] : pinCursorBlink(terminal, style.iterm.cursorBlink);
    const themeWatch = new MutationObserver(() => { terminal.options.theme = paneLook(style, pageLook()).colours; });
    if (look.followsPage) themeWatch.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
    const host = document.createElement('div');
    host.className = 'pane-terminal';
    return {
      showIn(container) {
        container.append(host);
        if (terminal.element === undefined) terminal.open(host);
      },
      fit() {
        const proposed = fitAddon.proposeDimensions();
        if (proposed !== undefined && !Number.isNaN(proposed.cols) && !Number.isNaN(proposed.rows)) {
          const size = paneSizeInBounds({ columns: proposed.cols, rows: proposed.rows });
          if (size.columns !== terminal.cols || size.rows !== terminal.rows) terminal.resize(size.columns, size.rows);
        }
        return { columns: terminal.cols, rows: terminal.rows };
      },
      write(bytes, drawn) { terminal.write(bytes, drawn); },
      onInput(listener) {
        terminal.onData((text) => listener(utf8Encoder.encode(text)));
        terminal.onBinary((text) => listener(Uint8Array.from(text, (character) => character.charCodeAt(0))));
      },
      focus() { terminal.focus(); },
      dispose() {
        themeWatch.disconnect();
        blinkPins.forEach((pin) => pin.dispose());
        terminal.dispose();
        host.remove();
      },
    };
  };
}
