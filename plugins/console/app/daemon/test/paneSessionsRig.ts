import { silentLogger } from '../src/log.ts';
import type { PaneFacts, PaneHost, PaneRequest } from '../src/panePlan.ts';
import type { PaneControl, PaneNotice } from '../src/paneProtocol.ts';
import { PaneSessions } from '../src/panes.ts';
import type { PaneLink, PtySpawner } from '../src/panes.ts';
import { fakePty } from './fakePty.ts';
import type { FakePty } from './fakePty.ts';
import { fakeScheduler } from './fakeSpawner.ts';

export const PROJECT = { id: 'app', root: '/p/app' };
export const OTHER_PROJECT = { id: 'site', root: '/p/site' };
const FACTS: PaneFacts = { folders: ['/p/app', '/p/app-wt-2', '/p/site'] };
export const HOST: PaneHost = { shell: '/bin/zsh', environment: { PATH: '/usr/bin' }, isFolder: () => true };
export const SHELL_AT_ROOT: PaneRequest = { folder: '/p/app', run: 'shell', size: { columns: 120, rows: 33 } };

type FakeLink = {
  link: PaneLink;
  /** Every chunk of output the link carried, in order. */
  output: Uint8Array[];
  notices: PaneNotice[];
  /** The close code, or null while the link is open. */
  ended: number | null;
  /** Bytes the socket holds, not yet written to the network. */
  queued: number;
  type(bytes: Uint8Array): void;
  control(control: PaneControl): void;
  go(): void;
};

function fakeLink(): FakeLink {
  let input: (bytes: Uint8Array) => void = () => {};
  let control: (control: PaneControl) => void = () => {};
  let gone: () => void = () => {};
  const fake: FakeLink = {
    output: [], notices: [], ended: null, queued: 0,
    link: {
      output: (bytes) => { fake.output.push(bytes); },
      tell: (notice) => { fake.notices.push(notice); },
      end: (code) => { fake.ended = code; },
      onInput: (listener) => { input = listener; },
      onControl: (listener) => { control = listener; },
      onGone: (listener) => { gone = listener; },
      queuedBytes: () => fake.queued,
    },
    type: (bytes) => input(bytes),
    control: (sent) => control(sent),
    go: () => gone(),
  };
  return fake;
}

export function sessions(refusal: string | null) {
  const { spawner, ptys } = fakePty(refusal);
  return sessionsOver(spawner, ptys);
}

/** Pane sessions over a given spawner; `ptys` is what the test reads back, empty for a spawner that starts none. */
export function sessionsOver(spawner: PtySpawner, ptys: FakePty[]) {
  const timers = fakeScheduler();
  const panes = new PaneSessions({ spawner, host: HOST, scheduler: timers.scheduler, log: silentLogger });
  const open = (request: PaneRequest, project: { id: string; root: string }): FakeLink => {
    const link = fakeLink();
    panes.open(project.id, request, FACTS, link.link);
    return link;
  };
  return { panes, ptys, timers, open };
}

/** The one pty a test opened; a missing one throws on first use. */
export function only(ptys: FakePty[]): FakePty {
  return ptys[0]!;
}

export const bytes = (text: string): Uint8Array => new TextEncoder().encode(text);
export const filler = (length: number): Uint8Array => new Uint8Array(length).fill(0x61);
