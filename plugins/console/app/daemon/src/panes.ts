import type { Scheduler } from './actions.ts';
import type { Logger } from './log.ts';
import type { PaneFacts, PaneHost, PaneLaunch, PaneRequest } from './panePlan.ts';
import { planPane } from './panePlan.ts';
import type { PaneControl, PaneNotice, PaneSize } from './paneProtocol.ts';
import { MAX_PANES, OUTPUT_HIGH_WATER_BYTES, OUTPUT_LOW_WATER_BYTES, PANE_CLOSE, PANE_KILL_GRACE_MS } from './paneProtocol.ts';

/** A started pty, as much of it as a pane needs. Injected so tests never load the addon. */
export type PtyHandle = {
  pid: number;
  onOutput(listener: (bytes: Uint8Array) => void): void;
  onExit(listener: (code: number | null, signal: string | null) => void): void;
  write(bytes: Uint8Array): void;
  resize(size: PaneSize): void;
  pause(): void;
  resume(): void;
  /** Signals the pty's process group. */
  signal(name: 'SIGHUP' | 'SIGKILL'): void;
  /** Closes the master, which hangs up whatever still holds the terminal. */
  close(): void;
};

/** Starts a pty, or says why it could not; never throws. */
export type PtySpawner = (launch: PaneLaunch, size: PaneSize, environment: Record<string, string>) => { ok: true; pty: PtyHandle } | { ok: false; error: string };

/** The page's end of one pane: its connection. */
export type PaneLink = {
  output(bytes: Uint8Array): void;
  tell(notice: PaneNotice): void;
  /** Closes the connection with a `PANE_CLOSE` code. */
  end(code: number): void;
  onInput(listener: (bytes: Uint8Array) => void): void;
  onControl(listener: (control: PaneControl) => void): void;
  /** Fires once, when the page's end closed or broke. */
  onGone(listener: () => void): void;
};

type PaneSessionsDependencies = { spawner: PtySpawner; host: PaneHost; scheduler: Scheduler; log: Logger };

/** Why a live pane is being hung up: its link went, its project is no longer watched, or the daemon stops. */
type HangUpCause = 'link-gone' | 'project-gone' | 'daemon-stopping';

type LivePane = {
  id: string;
  projectId: string;
  pty: PtyHandle;
  link: PaneLink;
  output: OutputFlow;
  /** Null while nothing ends the pane but its own process. */
  hangUp: { cause: HangUpCause; grace: object } | null;
  exited: Promise<void>;
};

/**
 * Every terminal pane of the daemon, across projects, at most `MAX_PANES` at once. A pane lives as
 * long as its link: the process's exit ends the link, and a link that goes hangs the process up,
 * then kills it after `PANE_KILL_GRACE_MS`. Output the page has not acked past the high water
 * pauses the pty until acks bring it under the low water. Logs `pane.open` and `pane.close`,
 * never what a pane shows or is sent.
 */
export class PaneSessions {
  private readonly spawner: PtySpawner;
  private readonly host: PaneHost;
  private readonly scheduler: Scheduler;
  private readonly log: Logger;
  private readonly live = new Set<LivePane>();
  private opened = 0;

  constructor(dependencies: PaneSessionsDependencies) {
    this.spawner = dependencies.spawner;
    this.host = dependencies.host;
    this.scheduler = dependencies.scheduler;
    this.log = dependencies.log;
  }

  /** Plans and starts a pane on the link, or tells the link why not and closes it `refused`. */
  open(project: { id: string; root: string }, request: PaneRequest, facts: PaneFacts, link: PaneLink): void {
    if (this.attachedPaneCount() >= MAX_PANES) { refuse(link, `${MAX_PANES} panes are open, the most the daemon runs at once; close one to open another`); return; }
    const planned = planPane(request, facts, this.host);
    if (!planned.ok) { refuse(link, planned.error); return; }
    const { launch } = planned;
    const spawned = this.spawner(launch, request.size, this.host.environment);
    if (!spawned.ok) { refuse(link, spawned.error); return; }
    this.opened += 1;
    const exited = Promise.withResolvers<void>();
    const pane: LivePane = { id: `pane-${this.opened}`, projectId: project.id, pty: spawned.pty, link, output: new OutputFlow(spawned.pty), hangUp: null, exited: exited.promise };
    this.live.add(pane);
    link.tell({ type: 'started', pane: pane.id, command: [launch.command, ...launch.args], folder: launch.cwd });
    pane.pty.onOutput((bytes) => { if (pane.hangUp === null) { link.output(bytes); pane.output.sent(bytes.byteLength); } });
    pane.pty.onExit((code, signal) => { this.conclude(pane, code, signal); exited.resolve(); });
    link.onInput((bytes) => { if (this.live.has(pane)) pane.pty.write(bytes); });
    link.onControl((control) => { if (this.live.has(pane)) applyControl(pane, control); });
    link.onGone(() => this.hangUp(pane, 'link-gone'));
    this.log.info('pane.open', { pane: pane.id, project: project.id, run: request.run, pid: pane.pty.pid });
  }

  /** Ends the project's links `projectGone`, then hangs their panes up and kills what is left after the grace, as for a lost link. */
  endProject(projectId: string): void {
    for (const pane of [...this.live]) {
      if (pane.projectId === projectId) this.endLink(pane, 'project-gone', PANE_CLOSE.projectGone);
    }
  }

  /** Ends every link `daemonStopping`, hangs every pane up and kills what is left after the grace; settles when every pty exited. */
  async stopAll(): Promise<void> {
    const stopping = [...this.live];
    for (const pane of stopping) this.endLink(pane, 'daemon-stopping', PANE_CLOSE.daemonStopping);
    await Promise.all(stopping.map((pane) => pane.exited));
  }

  private attachedPaneCount(): number {
    return [...this.live].filter((pane) => pane.hangUp === null).length;
  }

  private endLink(pane: LivePane, cause: HangUpCause, code: number): void {
    if (pane.hangUp !== null) return;
    this.hangUp(pane, cause);
    pane.link.end(code);
  }

  private hangUp(pane: LivePane, cause: HangUpCause): void {
    if (!this.live.has(pane) || pane.hangUp !== null) return;
    const grace = this.scheduler.after(PANE_KILL_GRACE_MS, () => { pane.pty.signal('SIGKILL'); pane.pty.close(); });
    pane.hangUp = { cause, grace };
    pane.pty.signal('SIGHUP');
  }

  private conclude(pane: LivePane, code: number | null, signal: string | null): void {
    if (!this.live.delete(pane)) return;
    this.log.info('pane.close', { pane: pane.id, code, signal, cause: pane.hangUp?.cause ?? 'exited' });
    if (pane.hangUp !== null) { this.scheduler.cancel(pane.hangUp.grace); return; }
    pane.link.tell({ type: 'exit', code, signal });
    pane.link.end(PANE_CLOSE.ended);
  }
}

function refuse(link: PaneLink, error: string): void {
  link.tell({ type: 'refused', error });
  link.end(PANE_CLOSE.refused);
}

function applyControl(pane: LivePane, control: PaneControl): void {
  switch (control.type) {
    case 'resize': pane.pty.resize({ cols: control.cols, rows: control.rows }); return;
    case 'ack': pane.output.acked(control.bytes); return;
  }
}

/** One pane's output the page has not acked yet, which pauses and resumes its pty. */
class OutputFlow {
  private readonly pty: PtyHandle;
  private unacked = 0;
  private state: 'flowing' | 'paused' = 'flowing';

  constructor(pty: PtyHandle) {
    this.pty = pty;
  }

  sent(byteCount: number): void {
    this.unacked += byteCount;
    if (this.state === 'flowing' && this.unacked > OUTPUT_HIGH_WATER_BYTES) { this.state = 'paused'; this.pty.pause(); }
  }

  acked(byteCount: number): void {
    this.unacked = Math.max(0, this.unacked - byteCount);
    if (this.state === 'paused' && this.unacked < OUTPUT_LOW_WATER_BYTES) { this.state = 'flowing'; this.pty.resume(); }
  }
}
