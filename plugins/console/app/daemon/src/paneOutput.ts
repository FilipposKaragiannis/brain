import type { Scheduler } from './actions.ts';
import { OUTPUT_HIGH_WATER_BYTES, OUTPUT_LOW_WATER_BYTES, PAUSED_EXIT_CHECK_MILLISECONDS } from './paneProtocol.ts';
import type { PaneLink, PtyHandle } from './panes.ts';

/**
 * One pane's output the page has not acked yet, and what its link still holds, which pause and
 * resume its pty. An ack counts no more than the bytes not yet acked, and a page that acks what it
 * never read is still held back by the bytes its link holds. node-pty drops what a paused pty still
 * holds 200 ms after its process ends, so a paused pty checks every `PAUSED_EXIT_CHECK_MILLISECONDS` whether
 * its process ended, and once it has, reads the rest and never pauses again.
 */
export class OutputFlow {
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

  sentMayPause(byteCount: number): void {
    this.unacked += byteCount;
    if (this.state === 'flowing' && this.pastHighWater()) this.pause();
  }

  ackedMayResume(byteCount: number): void {
    this.unacked -= Math.min(byteCount, this.unacked);
    if (this.state === 'paused' && this.underLowWater()) this.resume();
  }

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
