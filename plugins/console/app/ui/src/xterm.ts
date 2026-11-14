import { FitAddon } from '@xterm/addon-fit';
import { Terminal } from '@xterm/xterm';
import type { ITheme } from '@xterm/xterm';
import '@xterm/xterm/css/xterm.css';
import type { TerminalFactory } from './panes.ts';

const utf8Encoder = new TextEncoder();

const PANE_FONT_SIZE_PIXELS = 12;

/** The pane's colours and font, read from the stylesheet so the terminal follows the page's theme. */
function pageStyle(): { theme: ITheme; fontFamily: string } {
  const style = getComputedStyle(document.documentElement);
  const read = (property: string): string => style.getPropertyValue(property).trim();
  const theme: ITheme = {
    background: read('--terminal'),
    foreground: read('--terminal-ink'),
    cursor: read('--terminal-cursor'),
    cursorAccent: read('--terminal'),
    selectionBackground: read('--terminal-selection'),
  };
  return { theme, fontFamily: read('--terminal-font') };
}

/**
 * A pane's terminal on xterm.js, the one file that imports it. The terminal lives in a host
 * element of its own: the first `showIn` opens it there, a later one only moves the host, so a
 * second mount (StrictMode, a dock that re-renders) never opens it twice. Its colours follow the
 * page's light and dark themes.
 */
export const xtermTerminal: TerminalFactory = () => {
  const terminal = new Terminal({ ...pageStyle(), fontSize: PANE_FONT_SIZE_PIXELS });
  const fitAddon = new FitAddon();
  terminal.loadAddon(fitAddon);
  const themeWatch = new MutationObserver(() => { terminal.options.theme = pageStyle().theme; });
  themeWatch.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
  const host = document.createElement('div');
  host.className = 'pane-terminal';
  return {
    showIn(container) {
      container.append(host);
      if (terminal.element === undefined) terminal.open(host);
    },
    fit() {
      fitAddon.fit();
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
      terminal.dispose();
      host.remove();
    },
  };
};
