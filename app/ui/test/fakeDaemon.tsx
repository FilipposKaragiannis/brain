import type { ReactNode } from 'react';
import type { Disagreement, Readiness, FlowEvent, Gate, Item, ProcessInfo, Snapshot, Worktree } from '../../daemon/src/snapshot.ts';
import type { ActionRecord } from '../src/actions.ts';
import type { Api, ApiResponse, HttpMethod, StreamLike } from '../src/api.ts';
import { STREAM_CLOSED } from '../src/api.ts';
import { ClockProvider } from '../src/clock.tsx';
import { ServicesProvider } from '../src/console.tsx';
import { ActionsProvider } from '../src/ui.tsx';
import { useActions } from '../src/useActions.ts';
import { StreamHub } from '../src/stream.ts';

export const HTTP_OK = 200;
export const HTTP_ACCEPTED = 202;
export const HTTP_UNAUTHORIZED = 401;
export const HTTP_NOT_FOUND = 404;
export const HTTP_CONFLICT = 409;

const STREAM_CONNECTING = 0;
const STREAM_OPEN = 1;

/**
 * An event stream the test drives, modelled on EventSource: it starts CONNECTING, opens, carries
 * events, and on a network error goes back to CONNECTING (firing error) until it reopens by
 * itself; only `fail` closes it for good.
 */
export class FakeStream implements StreamLike {
  readyState = STREAM_CONNECTING;
  onopen: ((event: Event) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;
  private readonly listeners = new Map<string, ((event: MessageEvent<string>) => void)[]>();
  private readonly sent: () => void;

  constructor(sent: () => void) {
    this.sent = sent;
  }

  addEventListener(type: string, listener: (event: MessageEvent<string>) => void): void {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), listener]);
  }

  close(): void { this.readyState = STREAM_CLOSED; }

  open(): void { this.readyState = STREAM_OPEN; this.onopen?.(new Event('open')); }

  /** A network blip: the browser keeps the stream and retries it. */
  interrupt(): void { this.readyState = STREAM_CONNECTING; this.onerror?.(new Event('error')); }

  /** The browser's automatic retry succeeding. */
  reopen(): void { this.open(); }

  /** The browser gave up (a non-stream answer): closed for good. */
  fail(): void { this.readyState = STREAM_CLOSED; this.onerror?.(new Event('error')); }

  send(type: 'snapshot' | 'action' | 'projects', data: Snapshot | ActionRecord | unknown[]): void {
    const event = new MessageEvent<string>(type, { data: JSON.stringify(data) });
    (this.listeners.get(type) ?? []).forEach((listener) => listener(event));
    this.sent();
  }
}

type Route = (body: unknown) => ApiResponse;
type Held = { dueAt: number; release: () => void };

/** The daemon as the hooks see it: routes answered by the test, and every stream it opened. */
export class FakeDaemon implements Api {
  readonly streams: FakeStream[] = [];
  private readonly routes = new Map<string, { route: Route; afterEvents: number }>();
  private held: Held[] = [];
  private eventsSent = 0;

  answer(method: HttpMethod, path: string, route: Route): void {
    this.routes.set(`${method} ${path}`, { route, afterEvents: 0 });
  }

  /** Answers only once this many stream events went out after the request arrived: a slow reply. */
  answerAfterEvents(method: HttpMethod, path: string, events: number, route: Route): void {
    this.routes.set(`${method} ${path}`, { route, afterEvents: events });
  }

  async request(path: string, method: HttpMethod, body: unknown): Promise<ApiResponse> {
    const entry = this.routes.get(`${method} ${path}`);
    if (entry === undefined) return { status: HTTP_NOT_FOUND, body: { error: 'not found' } };
    if (entry.afterEvents > 0) {
      const dueAt = this.eventsSent + entry.afterEvents;
      await new Promise<void>((release) => { this.held.push({ dueAt, release }); });
    }
    return entry.route(body);
  }

  openStream(): StreamLike {
    const stream = new FakeStream(() => this.eventSent());
    this.streams.push(stream);
    return stream;
  }

  latestStream(): FakeStream {
    const stream = this.streams.at(-1);
    if (stream === undefined) throw new Error('no stream was opened');
    return stream;
  }

  wrapper(): (props: { children: ReactNode }) => ReactNode {
    const services = { api: this, hub: new StreamHub(this) };
    return ({ children }) => <ServicesProvider services={services}>{children}</ServicesProvider>;
  }

  /** What a screen sits in on the page: the services, a clock stopped at `TAKEN_AT`, and the project's actions. */
  screenWrapper(): (props: { children: ReactNode }) => ReactNode {
    const Services = this.wrapper();
    return ({ children }) => <Services><ClockProvider clock={stoppedClock}><WithActions>{children}</WithActions></ClockProvider></Services>;
  }

  private eventSent(): void {
    this.eventsSent += 1;
    const due = this.held.filter((entry) => entry.dueAt <= this.eventsSent);
    this.held = this.held.filter((entry) => entry.dueAt > this.eventsSent);
    due.forEach((entry) => entry.release());
  }
}

export const TAKEN_AT = '2026-10-24T18:16:04Z';

export function snapshotAt(takenAt: string, needsYou: number): Snapshot {
  const freshness = { at: takenAt, ageSeconds: 0, ok: true, error: null };
  return {
    schema: 2,
    takenAt,
    project: { id: 'project', name: 'project', root: '/p', flowHome: '/p/.flow', base: 'main', repo: 'owner/project', repoUrl: 'https://github.com/owner/project', trackerUrl: 'https://github.com/owner/project/issues', adapter: 'github', pluginVersion: '1.17.0', pluginRoot: '/home/owner/.claude/plugins/cache/brain/flow/1.17.0', pluginSource: 'installed', jobsHost: 'claude', poolMax: 9 },
    sources: { files: freshness, git: freshness, processes: freshness, jobs: freshness, board: freshness, pulls: freshness },
    counts: { needsYou, running: 0, stale: 0, claimed: 0, free: 0, agents: 0, jobsRunning: 0, itemsReady: 0, itemsBlocked: 0, itemsBacklog: 0, itemsDone: 0, disagreements: 0, pullsMergeable: 0, pullsFailing: 0, pullsChangesRequested: 0, needsField: 0 },
    readiness: { ready: 0, waitingOnField: 0, blocked: 0, gated: 0, nextInLineMissingField: 0 },
    attention: [], worktrees: [], items: [], gates: [], runs: [], agents: [], ended: [], jobs: [], events: [], disagreements: [], pulls: [],
  };
}

const PLUGIN = '/home/owner/.claude/plugins/flow';
export const ENDED_AT = '2026-10-24T18:16:40Z';

/** A `job.run` record in the daemon's shape: the job's lock, and the plugin's jobs.sh as the command. */
export function actionRecord(id: string, state: ActionRecord['state'], args: Record<string, string>): ActionRecord {
  const job = args.job ?? 'next';
  const ended = state !== 'running';
  return {
    id, kind: 'job.run', args, state, command: ['sh', `${PLUGIN}/scripts/jobs.sh`, 'run', job], locks: [`job:${job}`],
    requestedAt: TAKEN_AT, startedAt: TAKEN_AT, endedAt: ended ? ENDED_AT : null,
    exitCode: state === 'done' ? 0 : ended ? 1 : null, timedOut: false, outcome: state === 'done' ? 'started' : null, outputTail: '', outputBytes: 0,
  };
}

const stoppedClock = (): number => Date.parse(TAKEN_AT);

function WithActions({ children }: { children: ReactNode }) {
  return <ActionsProvider actions={useActions('project')}>{children}</ActionsProvider>;
}

/** A board item with its tracker page. */
export function boardItem(id: string, title: string): Item {
  return {
    id, title, kind: 'task', size: 'M', priority: 'P2', status: 'open', state: 'ready', step: '', gate: 'none', worktree: null, pr: null,
    url: `https://github.com/owner/project/issues/${id.replace(/^gh#/, '')}`, parent: null, blockedBy: [], openBlockers: [], openChildren: 0, needs: [], rank: 1, lastEvent: null,
  };
}

/** A free pool worktree; tests spread what they need over it. */
export function poolWorktree(name: string): Worktree {
  return {
    name, path: `/p-wt/${name}`, role: 'pool', state: 'free', flags: [], branch: null, head: null, aheadOfBase: 0, behindBase: 0, dirtyFiles: 0,
    lastCommitAt: null, claim: null, claimAgeSeconds: null, item: null, itemUrl: null, itemTitle: null, gate: null, staleReason: null, agents: [], sessions: [],
  };
}

export function claudeSession(pid: number, elapsedSeconds: number): ProcessInfo {
  return { pid, host: 'claude', command: `/Applications/Claude.app/claude --session ${pid}`, elapsedSeconds, session: null };
}

export function waitingGate(item: string, gate: string): Gate {
  return { item, gate, message: '1. Which way?', raisedAt: TAKEN_AT, ageSeconds: 600, overdue: false, host: 'claude', worktree: null, questions: [{ number: 1, text: 'Which way?', recommended: null }], pull: null };
}

export function boardDisagreement(item: string): Disagreement {
  return {
    item, worktree: null, sources: ['gate record', 'issue labels'], message: `${item}: the gate record says merge, the labels say none.`,
    explain: 'The gate record says merge while the labels show no gate; the gate record is usually right and the labels catch up.',
    action: { kind: 'refresh', args: { source: 'board' }, label: 'Re-read the board' },
  };
}

export function flowEvent(item: string | null, kind: string, message: string): FlowEvent {
  return { at: TAKEN_AT, item, kind, message };
}

/** Readiness with every bucket empty but the ones a test names. */
export function readiness(buckets: Partial<Readiness>): Readiness {
  return { ready: 0, waitingOnField: 0, blocked: 0, gated: 0, nextInLineMissingField: 0, ...buckets };
}
