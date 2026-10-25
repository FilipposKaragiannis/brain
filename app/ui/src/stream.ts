import type { Snapshot } from '../../daemon/src/snapshot.ts';
import type { ActionRecord } from './actions.ts';
import { projectPath, STREAM_CLOSED } from './api.ts';
import type { Api, StreamLike } from './api.ts';

/** `connecting` before the first open, `open` while events flow, `down` once the stream errored. */
export type LinkState = 'connecting' | 'open' | 'down';

export type StreamListener = {
  snapshot(snapshot: Snapshot): void;
  action(action: ActionRecord): void;
  link(state: LinkState): void;
};

type Channel = { stream: StreamLike | null; link: LinkState; listeners: Set<StreamListener> };

/**
 * One event stream per project, shared by every hook that listens to it, so the snapshot and
 * the action updates arrive on a single connection. A stream the browser gave up on is
 * reopened by `reconnect`, which the polling fallback calls on each tick.
 */
export class StreamHub {
  private readonly channels = new Map<string, Channel>();
  private readonly api: Api;

  constructor(api: Api) {
    this.api = api;
  }

  subscribe(projectId: string, listener: StreamListener): () => void {
    const channel = this.channelFor(projectId);
    channel.listeners.add(listener);
    listener.link(channel.link);
    return () => {
      channel.listeners.delete(listener);
      if (channel.listeners.size > 0) return;
      channel.stream?.close();
      this.channels.delete(projectId);
    };
  }

  reconnect(projectId: string): void {
    const channel = this.channels.get(projectId);
    if (channel === undefined || channel.link === 'open') return;
    channel.stream?.close();
    this.open(projectId, channel);
  }

  private channelFor(projectId: string): Channel {
    const existing = this.channels.get(projectId);
    if (existing !== undefined) return existing;
    const channel: Channel = { stream: null, link: 'connecting', listeners: new Set() };
    this.channels.set(projectId, channel);
    this.open(projectId, channel);
    return channel;
  }

  private open(projectId: string, channel: Channel): void {
    const stream = this.api.openStream(projectPath(projectId, '/events'));
    channel.stream = stream;
    stream.addEventListener('snapshot', (event) => {
      const snapshot = parseEvent<Snapshot>(event);
      if (snapshot !== null) channel.listeners.forEach((listener) => listener.snapshot(snapshot));
    });
    stream.addEventListener('action', (event) => {
      const action = parseEvent<ActionRecord>(event);
      if (action !== null) channel.listeners.forEach((listener) => listener.action(action));
    });
    stream.onopen = () => setLink(channel, 'open');
    stream.onerror = () => {
      if (stream.readyState === STREAM_CLOSED) channel.stream = null;
      setLink(channel, 'down');
    };
  }
}

function setLink(channel: Channel, link: LinkState): void {
  if (channel.link === link) return;
  channel.link = link;
  channel.listeners.forEach((listener) => listener.link(link));
}

function parseEvent<T>(event: MessageEvent<string>): T | null {
  try { return JSON.parse(event.data) as T; } catch { return null; }
}
