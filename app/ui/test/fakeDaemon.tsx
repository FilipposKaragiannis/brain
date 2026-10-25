import type { ReactNode } from 'react';
import type { Snapshot } from '../../daemon/src/snapshot.ts';
import type { ActionRecord } from '../src/actions.ts';
import type { Api, ApiResponse, StreamLike } from '../src/api.ts';
import { STREAM_CLOSED } from '../src/api.ts';
import { ServicesProvider } from '../src/console.tsx';
import { StreamHub } from '../src/stream.ts';

const STREAM_OPEN = 1;

/** An event stream the test drives: it opens, carries events, and drops. */
export class FakeStream implements StreamLike {
  readyState = 0;
  onopen: ((event: Event) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;
  private readonly listeners = new Map<string, ((event: MessageEvent<string>) => void)[]>();

  addEventListener(type: string, listener: (event: MessageEvent<string>) => void): void {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), listener]);
  }

  close(): void { this.readyState = STREAM_CLOSED; }

  open(): void { this.readyState = STREAM_OPEN; this.onopen?.(new Event('open')); }

  send(type: 'snapshot' | 'action', data: Snapshot | ActionRecord): void {
    const event = new MessageEvent<string>(type, { data: JSON.stringify(data) });
    (this.listeners.get(type) ?? []).forEach((listener) => listener(event));
  }

  drop(): void { this.readyState = STREAM_CLOSED; this.onerror?.(new Event('error')); }
}

type Route = (body: unknown) => ApiResponse;

/** The daemon as the hooks see it: routes answered by the test, and every stream it opened. */
export class FakeDaemon implements Api {
  readonly streams: FakeStream[] = [];
  private readonly routes = new Map<string, Route>();

  answer(method: 'GET' | 'POST', path: string, route: Route): void {
    this.routes.set(`${method} ${path}`, route);
  }

  async request(path: string, method: 'GET' | 'POST', body: unknown): Promise<ApiResponse> {
    const route = this.routes.get(`${method} ${path}`);
    return route === undefined ? { status: 404, body: { error: 'not found' } } : route(body);
  }

  openStream(): StreamLike {
    const stream = new FakeStream();
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
}

export const TAKEN_AT = '2026-10-24T18:16:04Z';

export function snapshotAt(takenAt: string, needsYou: number): Snapshot {
  const freshness = { at: takenAt, ageSeconds: 0, ok: true, error: null };
  return {
    schema: 1,
    takenAt,
    project: { id: 'project', name: 'project', root: '/p', flowHome: '/p/.flow', base: 'main', repo: 'owner/project', adapter: 'github', pluginVersion: '1.17.0', poolMax: 9 },
    sources: { files: freshness, git: freshness, processes: freshness, jobs: freshness, board: freshness },
    counts: { needsYou, running: 0, stale: 0, claimed: 0, free: 0, agents: 0, jobsRunning: 0, itemsReady: 0, itemsBlocked: 0, itemsBacklog: 0, itemsDone: 0, disagreements: 0 },
    attention: [], worktrees: [], items: [], gates: [], runs: [], agents: [], jobs: [], events: [], disagreements: [],
  };
}

export function actionRecord(id: string, state: ActionRecord['state'], args: Record<string, string>): ActionRecord {
  return {
    id, kind: 'job.run', args, state, command: ['scripts/jobs.sh', 'run', args.job ?? ''], lock: 'jobs',
    requestedAt: TAKEN_AT, startedAt: state === 'queued' ? null : TAKEN_AT, endedAt: null,
    exitCode: state === 'done' ? 0 : null, timedOut: false, outputTail: '', outputBytes: 0,
  };
}
