import { FitAddon } from '@xterm/addon-fit';
import { Terminal } from '@xterm/xterm';
import '@xterm/xterm/css/xterm.css';
import type { TerminalFactory } from './panes.ts';

const utf8Encoder = new TextEncoder();

/**
 * A pane's terminal on xterm.js, the one file that imports it. The terminal lives in a host
 * element of its own: the first `showIn` opens it there, a later one only moves the host, so a
 * second mount (StrictMode, a dock that re-renders) never opens it twice.
 */
export const xtermTerminal: TerminalFactory = () => {
  const terminal = new Terminal();
  const fitAddon = new FitAddon();
  terminal.loadAddon(fitAddon);
  const host = document.createElement('div');
  host.className = 'pane-terminal';
  return {
    showIn(container) {
      container.append(host);
      if (terminal.element === undefined) terminal.open(host);
    },
    fit() {
      fitAddon.fit();
      return { cols: terminal.cols, rows: terminal.rows };
    },
    write(bytes, drawn) { terminal.write(bytes, drawn); },
    onInput(listener) {
      terminal.onData((text) => listener(utf8Encoder.encode(text)));
      terminal.onBinary((text) => listener(Uint8Array.from(text, (character) => character.charCodeAt(0))));
    },
    focus() { terminal.focus(); },
    dispose() {
      terminal.dispose();
      host.remove();
    },
  };
};
