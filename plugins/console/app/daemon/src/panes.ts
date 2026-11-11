import type { Scheduler } from './actions.ts';
import type { Logger } from './log.ts';
import { errorMessage } from './log.ts';
import type { PaneFacts, PaneHost, PaneLaunch, PaneRequest } from './panePlan.ts';
import { planPane } from './panePlan.ts';
import type { PaneControl, PaneNotice, PaneSize } from './paneProtocol.ts';
import { MAXIMUM_PANES, OUTPUT_HIGH_WATER_BYTES, OUTPUT_LOW_WATER_BYTES, PANE_CLOSE, PANE_KILL_GRACE_MILLISECONDS, PAUSED_EXIT_CHECK_MILLISECONDS } from './paneProtocol.ts';

/** A started pty, as much of it as a pane needs. Injected so tests never load the addon. */
export type PtyHandle = {
  pid: number;
  onOutput(listener: (bytes: Uint8Array) => void): void;
  onExit(listener: (code: number | null, signal: string | null) => void): void;
  write(bytes: Uint8Array): void;
  resize(size: PaneSize): void;
  pause(): void;
  resume(): void;
  /** Whether the process the pty started is still running. */
  running(): boolean;
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
  /** Bytes the connection holds that have not left for the page yet. */
  queuedBytes(): number;
};

type PaneSessionsDependencies = { spawner: PtySpawner; host: PaneHost; scheduler: Scheduler; log: Logger };

/** A pane's process started: what it runs and its pty. */
type StartedPane = { launch: PaneLaunch; pty: PtyHandle };

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
 * Every terminal pane of the daemon, across projects, at most `MAXIMUM_PANES` at once; a hung-up pane
 * counts until its process ended. A pane lives as long as its link: the process's exit ends the
 * link, and a link that goes hangs the process up, then kills it after `PANE_KILL_GRACE_MILLISECONDS`.
 * Output the page has not acked, or the link still holds, past the high water pauses the pty until
 * both are under the low water. Logs `pane.open` and `pane.close`, never what a pane shows or is sent.
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

  /** Plans and starts a pane of the project on the link, or tells the link why not and closes it `refused`. */
  open(projectId: string, request: PaneRequest, facts: PaneFacts, link: PaneLink): void {
    if (this.live.size >= MAXIMUM_PANES) { refuse(link, `${MAXIMUM_PANES} panes are open, the most the daemon runs at once; close one to open another`); return; }
    const started = this.spawnFor(request, facts);
    if (!started.ok) { refuse(link, started.error); return; }
    const pane = this.register(projectId, started, link);
    this.log.info('pane.open', { pane: pane.id, project: projectId, run: request.run, pid: pane.pty.pid });
  }

  private spawnFor(request: PaneRequest, facts: PaneFacts): ({ ok: true } & StartedPane) | { ok: false; error: string } {
    const planned = planPane(request, facts, this.host);
    if (!planned.ok) return planned;
    const spawned = this.spawner(planned.launch, request.size, this.host.environment);
    return spawned.ok ? { ok: true, launch: planned.launch, pty: spawned.pty } : spawned;
  }

  /** Counts the started pane live, tells the link it started, and wires its pty and its link to each other. */
  private register(projectId: string, started: StartedPane, link: PaneLink): LivePane {
    this.opened += 1;
    const exited = Promise.withResolvers<void>();
    const { launch, pty } = started;
    const pane: LivePane = { id: `pane-${this.opened}`, projectId, pty, link, output: new OutputFlow(pty, link, this.scheduler), hangUp: null, exited: exited.promise };
    this.live.add(pane);
    link.tell({ type: 'started', pane: pane.id, command: [launch.command, ...launch.commandArguments], folder: launch.workingFolder });
    pty.onOutput((bytes) => this.forward(pane, bytes));
    pty.onExit((code, signal) => { this.conclude(pane, code, signal); exited.resolve(); });
    this.listen(pane);
    return pane;
  }

  private listen(pane: LivePane): void {
    pane.link.onInput((bytes) => this.toPty(pane, 'input', () => pane.pty.write(bytes)));
    pane.link.onControl((control) => this.toPty(pane, control.type, () => applyControl(pane, control)));
    pane.link.onGone(() => this.hangUp(pane, 'link-gone'));
  }

  /**
   * Hands a frame from the page to the pane's pty while the pane is live and not hung up: once it
   * is, the grace may already have closed the terminal. A pty that throws all the same is logged,
   * never thrown out of the link's listener.
   */
  private toPty(pane: LivePane, frame: string, deliver: () => void): void {
    if (!this.live.has(pane) || pane.hangUp !== null) return;
    try {
      deliver();
    } catch (error) {
      this.log.warn('pane.frame', { pane: pane.id, frame, error: errorMessage(error) });
    }
  }

  private forward(pane: LivePane, bytes: Uint8Array): void {
    if (pane.hangUp !== null) return;
    pane.link.output(bytes);
    pane.output.sentMayPause(bytes.byteLength);
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

  private endLink(pane: LivePane, cause: HangUpCause, code: number): void {
    if (pane.hangUp !== null) return;
    this.hangUp(pane, cause);
    pane.link.end(code);
  }

  private hangUp(pane: LivePane, cause: HangUpCause): void {
    if (!this.live.has(pane) || pane.hangUp !== null) return;
    const grace = this.scheduler.after(PANE_KILL_GRACE_MILLISECONDS, () => { pane.pty.signal('SIGKILL'); pane.pty.close(); });
    pane.hangUp = { cause, grace };
    pane.output.resumeForHangUp();
    pane.pty.signal('SIGHUP');
  }

  private conclude(pane: LivePane, code: number | null, signal: string | null): void {
    if (!this.live.delete(pane)) return;
    pane.output.stop();
    this.log.info('pane.close', { pane: pane.id, code, signal, cause: pane.hangUp?.cause ?? 'exited' });
    if (pane.hangUp !== null) { this.scheduler.cancel(pane.hangUp.grace); return; }
    pane.link.tell({ type: 'exit', code, signal });
    pane.link.end(PANE_CLOSE.ended);
  }
}

/** Tells the link why its pane does not start, then closes it `refused`. */
export function refuse(link: PaneLink, error: string): void {
  link.tell({ type: 'refused', error });
  link.end(PANE_CLOSE.refused);
}

function applyControl(pane: LivePane, control: PaneControl): void {
  switch (control.type) {
    case 'resize': pane.pty.resize({ columns: control.cols, rows: control.rows }); return;
    case 'ack': pane.output.ackedMayResume(control.bytes); return;
  }
}

/**
 * One pane's output the page has not acked yet, and what its link still holds, which pause and
 * resume its pty. An ack counts no more than the bytes not yet acked, and a page that acks what it
 * never read is still held back by the bytes its link holds. node-pty drops what a paused pty still
 * holds 200 ms after its process ends, so a paused pty checks every `PAUSED_EXIT_CHECK_MILLISECONDS` whether
 * its process ended, and once it has, reads the rest and never pauses again.
 */
class OutputFlow {
  private readonly pty: PtyHandle;
  private readonly link: PaneLink;
  private readonly scheduler: Scheduler;
  private unacked = 0;
  private state: 'flowing' | 'paused' | 'ended' = 'flowing';
  private exitCheck: object | null = null;

  constructor(pty: PtyHandle, link: PaneLink, scheduler: Scheduler) {
    this.pty = pty;
    this.link = link;
    this.scheduler = scheduler;
  }

  /** Counts bytes sent to the page, and pauses the pty once they or the link's queue pass the high water. */
  sentMayPause(byteCount: number): void {
    this.unacked += byteCount;
    if (this.state === 'flowing' && this.pastHighWater()) this.pause();
  }

  /** Counts bytes the page drew, and resumes a paused pty once both the unacked bytes and the link's queue are under the low water. */
  ackedMayResume(byteCount: number): void {
    this.unacked -= Math.min(byteCount, this.unacked);
    if (this.state === 'paused' && this.underLowWater()) this.resume();
  }

  /** Resumes a paused pty, so the hung-up process can write and its end reach the daemon. */
  resumeForHangUp(): void {
    if (this.state === 'paused') this.resume();
  }

  private pastHighWater(): boolean {
    return this.unacked > OUTPUT_HIGH_WATER_BYTES || this.link.queuedBytes() > OUTPUT_HIGH_WATER_BYTES;
  }

  private underLowWater(): boolean {
    return this.unacked < OUTPUT_LOW_WATER_BYTES && this.link.queuedBytes() < OUTPUT_LOW_WATER_BYTES;
  }

  /** Stops checking on the process; its pane has ended. */
  stop(): void {
    this.cancelExitCheck();
  }

  private pause(): void {
    this.state = 'paused';
    this.pty.pause();
    this.checkExitLater();
  }

  private resume(): void {
    this.cancelExitCheck();
    this.state = 'flowing';
    this.pty.resume();
  }

  private checkExitLater(): void {
    this.exitCheck = this.scheduler.after(PAUSED_EXIT_CHECK_MILLISECONDS, () => this.resumeOnceExited());
  }

  private resumeOnceExited(): void {
    if (this.pty.running()) { this.checkExitLater(); return; }
    this.exitCheck = null;
    this.state = 'ended';
    this.pty.resume();
  }

  private cancelExitCheck(): void {
    if (this.exitCheck === null) return;
    this.scheduler.cancel(this.exitCheck);
    this.exitCheck = null;
  }
}
