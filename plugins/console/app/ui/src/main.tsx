import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { browserApi, readToken } from './api.ts';
import { App } from './App.tsx';
import { ClockProvider } from './clock.tsx';
import { ServicesProvider } from './console.tsx';
import { PaneStore } from './panes.ts';
import { StreamHub } from './stream.ts';
import { loadTerminalStyle } from './terminalStyle.ts';
import { applyTheme, storedTheme } from './theme.tsx';
import { browserFontInstaller, paintPaneBackground, xtermTerminals } from './xterm.ts';
import './styles.css';

applyTheme(storedTheme());

const token = readToken(window.location.search);
if (token !== null) {
  const withoutToken = new URL(window.location.href);
  withoutToken.searchParams.delete('token');
  window.history.replaceState(window.history.state, '', withoutToken.toString());
}
const api = browserApi(token);
const terminalStyle = await loadTerminalStyle(api, browserFontInstaller);
paintPaneBackground(terminalStyle);
const services = { api, hub: new StreamHub(api), panes: new PaneStore(api, xtermTerminals(terminalStyle)) };
const systemClock = (): number => Date.now();
const root = document.getElementById('root');
if (root === null) throw new Error('index.html has no #root');

createRoot(root).render(
  <StrictMode>
    <ServicesProvider services={services}>
      <ClockProvider clock={systemClock}>
        <App />
      </ClockProvider>
    </ServicesProvider>
  </StrictMode>,
);
