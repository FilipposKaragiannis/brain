import type { Scheduler } from './actions.ts';
import type { Logger } from './log.ts';
import { errorMessage } from './log.ts';
import { OutputFlow } from './paneOutput.ts';
import type { PaneFacts, PaneHost, PaneLaunch, PaneRequest } from './panePlan.ts';
import { planPane } from './panePlan.ts';
import type { PaneControl, PaneNotice, PaneSize } from './paneProtocol.ts';
import { MAXIMUM_PANES, PANE_CLOSE, PANE_KILL_GRACE_MILLISECONDS } from './paneProtocol.ts';

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
  /** Whether any process of the pty's process group still runs: the process the pty started, or one it left there. */
  groupRunning(): boolean;
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

type HangUpCause = 'link-gone' | 'project-gone' | 'daemon-stopping';

type LivePane = {
  id: string;
  projectId: string;
  pty: PtyHandle;
  link: PaneLink;
  output: OutputFlow;
  /** Null while nothing ends the pane but its own process; `grace` is null once it ran out. */
  hangUp: { cause: HangUpCause; grace: object | null } | null;
  /** Settles once nothing the pane started runs: its process ended and, once hung up, its group was empty or killed. */
  finished: PromiseWithResolvers<void>;
};

/**
 * Every terminal pane of the daemon, across projects, at most `MAXIMUM_PANES` at once; a hung-up pane
 * counts until its process ended. A pane lives as long as its link: the process's exit ends the
 * link, and a link that goes hangs the process group up, then kills it after `PANE_KILL_GRACE_MILLISECONDS`,
 * also when the process ended on the hang-up but left a process in its group. The grace keeps the
 * daemon's process alive, so a stopping daemon kills what a pane left before it exits.
 * Output the page has not acked, or the link still holds, past the high water pauses the pty until
 * both are under the low water. Logs `pane.open` and `pane.close`, never what a pane shows or is sent.
 */
export class PaneSessions {
  private readonly spawner: PtySpawner;
  private readonly host: PaneHost;
  private readonly scheduler: Scheduler;
  private readonly log: Logger;
  private readonly live = new Set<LivePane>();
  /** Hung-up panes whose process ended but whose group still holds a process the grace has yet to kill. */
  private readonly finishing = new Set<LivePane>();
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
    this.log.info('pane.open', { pane: pane.id, project: projectId, run: request.target.run, pid: pane.pty.pid });
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
    const { launch, pty } = started;
    const pane: LivePane = { id: `pane-${this.opened}`, projectId, pty, link, output: new OutputFlow(pty, link, this.scheduler), hangUp: null, finished: Promise.withResolvers<void>() };
    this.live.add(pane);
    link.tell({ type: 'started', pane: pane.id, command: [launch.command, ...launch.commandArguments], folder: launch.workingFolder });
    pty.onOutput((bytes) => this.forward(pane, bytes));
    pty.onExit((code, signal) => this.conclude(pane, code, signal));
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

  /**
   * Ends every link `daemonStopping`, hangs every pane up and kills what is left after the grace;
   * settles when every pane finished, a pane closed before the stop and still in its grace too.
   */
  async stopAll(): Promise<void> {
    const stopping = [...this.live];
    for (const pane of stopping) this.endLink(pane, 'daemon-stopping', PANE_CLOSE.daemonStopping);
    await Promise.all([...stopping, ...this.finishing].map((pane) => pane.finished.promise));
  }

  private endLink(pane: LivePane, cause: HangUpCause, code: number): void {
    if (pane.hangUp !== null) return;
    this.hangUp(pane, cause);
    pane.link.end(code);
  }

  private hangUp(pane: LivePane, cause: HangUpCause): void {
    if (!this.live.has(pane) || pane.hangUp !== null) return;
    const grace = this.scheduler.afterKeepingAlive(PANE_KILL_GRACE_MILLISECONDS, () => this.killAfterGrace(pane, cause));
    pane.hangUp = { cause, grace };
    pane.output.resumeForHangUp();
    pane.pty.signal('SIGHUP');
  }

  /**
   * Kills the pane's process group while it still holds a process: a group that emptied during the
   * grace is not signalled, as its id is free for the system to hand out again. Closes the master
   * while its process still runs, whose exit then finishes the pane. An ended pty is left alone:
   * node-pty closed it before telling the exit, and its close hangs up the bare pid once more; the
   * pane has finished with the kill.
   */
  private killAfterGrace(pane: LivePane, cause: HangUpCause): void {
    pane.hangUp = { cause, grace: null };
    const processRunning = this.live.has(pane);
    if (pane.pty.groupRunning()) pane.pty.signal('SIGKILL');
    if (processRunning) { pane.pty.close(); return; }
    this.finishing.delete(pane);
    pane.finished.resolve();
  }

  private conclude(pane: LivePane, code: number | null, signal: string | null): void {
    if (!this.live.delete(pane)) return;
    pane.output.stop();
    this.log.info('pane.close', { pane: pane.id, code, signal, cause: pane.hangUp?.cause ?? 'exited' });
    if (pane.hangUp !== null) { this.concludeHungUp(pane, pane.hangUp.grace); return; }
    pane.link.tell({ type: 'exit', code, signal });
    pane.link.end(PANE_CLOSE.ended);
    pane.finished.resolve();
  }

  /**
   * A hung-up pane whose process ended. While its group still holds a process and the grace has yet
   * to run out, the pane waits for the grace to kill it. Else the pane has finished, and a grace
   * still armed is cancelled: the empty group's id is free for the system to hand out again, so it
   * is not signalled, and nothing holds the daemon.
   */
  private concludeHungUp(pane: LivePane, grace: object | null): void {
    if (grace !== null && pane.pty.groupRunning()) { this.finishing.add(pane); return; }
    if (grace !== null) this.scheduler.cancel(grace);
    pane.finished.resolve();
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
