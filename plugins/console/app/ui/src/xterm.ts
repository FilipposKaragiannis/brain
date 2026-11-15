import { FitAddon } from '@xterm/addon-fit';
import { Terminal } from '@xterm/xterm';
import '@xterm/xterm/css/xterm.css';
import type { TerminalFactory } from './panes.ts';
import type { FontInstaller, PageLook, TerminalStyle } from './terminalStyle.ts';
import { paneLook } from './terminalStyle.ts';

const utf8Encoder = new TextEncoder();

/** The stylesheet's custom property the pane dock paints behind a terminal. */
const PANE_BACKGROUND_PROPERTY = '--pane-background';

/** The pane's colours and font, read from the stylesheet so the terminal follows the page's theme. */
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

/** Installs the font file as a `FontFace` of the family once the browser has loaded it. */
export const browserFontInstaller: FontInstaller = async (family, bytes) => {
  try {
    const face = new FontFace(family, bytes);
    await face.load();
    document.fonts.add(face);
    return true;
  } catch {
    return false;
  }
};

/** Paints the dock behind the panes in the iTerm profile's background, so the edge around a terminal matches it; without one the stylesheet's stays. */
export function paintPaneBackground(style: TerminalStyle): void {
  const background = style.iterm?.colours.background;
  if (background !== undefined) document.documentElement.style.setProperty(PANE_BACKGROUND_PROPERTY, background);
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
}
