import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { browserApi, readToken } from './api.ts';
import { App } from './App.tsx';
import { ClockProvider } from './clock.tsx';
import { ServicesProvider } from './console.tsx';
import { StreamHub } from './stream.ts';
import './styles.css';

const api = browserApi(readToken(window.location.search));
const services = { api, hub: new StreamHub(api) };
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
