import { createContext, useContext, useState } from 'react';
import type { ReactNode } from 'react';
import type { Freshness, SourceName } from '../../daemon/src/snapshot.ts';
import type { ActionKind } from './actions.ts';
import { actionStateLabel } from './actions.ts';
import { Since, useNow } from './clock.tsx';
import { actionRecordTone, freshnessTone } from './status.ts';
import type { Tone } from './status.ts';
import type { ActionOutcome, ActionsView } from './useActions.ts';

export function Dot({ tone }: { tone: Tone }) {
  return <span className={`dot tone-${tone}`} aria-hidden="true" />;
}

export function Chip({ tone, children }: { tone: Tone; children: ReactNode }) {
  return <span className={`chip tone-${tone}`}><Dot tone={tone} />{children}</span>;
}

export function Flags({ flags }: { flags: readonly string[] }) {
  if (flags.length === 0) return null;
  return <span className="flags">{flags.map((flag) => <span key={flag} className="flag" title={flag}>{flag}</span>)}</span>;
}

/** The freshness line every module ends with: which source it reads, how old that read is, and any error. */
export function SourceFreshness({ name, freshness }: { name: SourceName; freshness: Freshness }) {
  const tone = freshnessTone(freshness);
  return (
    <span className={`freshness tone-${tone}`}>
      <Dot tone={tone} />{name} · <Since at={freshness.at} />
      {freshness.error !== null && <span className="freshness-error" title={freshness.error}> · {freshness.error}</span>}
    </span>
  );
}

/** The one module shape: a title row, a body, and a footer that says how fresh the body is. */
export function Module({ title, aside, footer, children, className }: { title: ReactNode; aside: ReactNode; footer: ReactNode; children: ReactNode; className: string }) {
  return (
    <section className={`module ${className}`}>
      <header className="module-head"><h2>{title}</h2>{aside}</header>
      <div className="module-body">{children}</div>
      <footer className="module-foot">{footer}</footer>
    </section>
  );
}

export function Empty({ children }: { children: ReactNode }) {
  return <p className="empty">{children}</p>;
}

const ActionsContext = createContext<ActionsView | null>(null);

export function ActionsProvider({ actions, children }: { actions: ActionsView; children: ReactNode }) {
  return <ActionsContext.Provider value={actions}>{children}</ActionsContext.Provider>;
}

export function useActionsView(): ActionsView {
  const actions = useContext(ActionsContext);
  if (actions === null) throw new Error('useActionsView needs an ActionsProvider above it');
  return actions;
}

/** The label every Open in Terminal button carries. */
export const OPEN_IN_TERMINAL = 'Open in Terminal';

/** Opens a terminal in a folder the snapshot lists, or, with a job, follows that job's log from the project root. */
export function TerminalButton({ path, job }: { path: string; job?: string }) {
  return <ActionButton kind="terminal.open" args={job === undefined ? { path } : { path, job }} label={OPEN_IN_TERMINAL} primary={false} />;
}

export const OPEN_SESSION = 'Open session';
export const OPEN_SESSION_LIVE = 'Opens a terminal at the worktree with the resume command ready. The run is still going, so press Enter once it ends.';
export const OPEN_SESSION_ENDED = 'Opens a terminal at the worktree and resumes the session.';

/**
 * Hands the owner an agent's session: a terminal in the folder it ran in with its resume command,
 * typed but not run while the process still runs, run at once once it has ended.
 */
export function SessionButton({ path, pid, alive }: { path: string; pid: number; alive: boolean }) {
  return <ActionButton kind="terminal.open" args={{ path, session: String(pid) }} label={OPEN_SESSION} primary title={alive ? OPEN_SESSION_LIVE : OPEN_SESSION_ENDED} />;
}

/** How long a button keeps saying how its last press ended: a short while for success, longer for a failure. */
export const OUTCOME_SHOWN_MS = 8000;
export const FAILURE_SHOWN_MS = 30000;

/**
 * A button that runs one action, stays disabled while that action runs, and says for a while how it
 * ended. With `sharesOutcomeWith`, it says how the newer of its own press and a press of that other
 * kind ended, so a button that takes the place of another keeps the feedback of the press before it.
 * With `blockedBy`, it stays disabled and says that reason on hover, so a press the daemon would
 * refuse is visible but never sent.
 */
export function ActionButton({ kind, args, label, primary, title, sharesOutcomeWith, blockedBy }: { kind: ActionKind; args: Record<string, string>; label: string; primary: boolean; title?: string | undefined; sharesOutcomeWith?: ActionKind | undefined; blockedBy?: string | null | undefined }) {
  const actions = useActionsView();
  const busy = actions.busy(kind, args);
  const blocked = blockedBy !== undefined && blockedBy !== null;
  const outcome = useFadingOutcome(newerOutcome(actions.outcome(kind, args), sharesOutcomeWith === undefined ? null : actions.outcome(sharesOutcomeWith, args)));
  return (
    <span className="action">
      <button type="button" className={primary ? 'button primary' : 'button'} disabled={busy || blocked} title={blockedBy ?? title} onClick={() => { void actions.run(kind, args); }}>
        {busy ? `${label}…` : label}
      </button>
      {outcome?.kind === 'refused' && <span className="chip tone-failing" title={outcome.message}>{outcome.message}</span>}
      {outcome?.kind === 'started' && <Chip tone={actionRecordTone(outcome.record)}>{actionStateLabel(outcome.record)}{outcome.record.exitCode !== null && outcome.record.exitCode !== 0 ? ` (exit ${outcome.record.exitCode})` : ''}</Chip>}
      {outcome?.kind === 'started' && outcome.record.note !== null && <span className="muted action-note">{outcome.record.note}</span>}
    </span>
  );
}

/**
 * The outcome while it is worth showing. A running action shows until it ends. Then the chip
 * stays `OUTCOME_SHOWN_MS`, or `FAILURE_SHOWN_MS` for a failure or a refusal, counted from the
 * moment this button first saw that ending.
 */
function useFadingOutcome(outcome: ActionOutcome | null): ActionOutcome | null {
  const now = useNow();
  const key = outcomeKey(outcome);
  const [seen, setSeen] = useState({ key, at: now });
  if (seen.key !== key) {
    setSeen({ key, at: now });
    return outcome;
  }
  if (outcome === null) return null;
  if (outcome.kind === 'started' && outcome.record.state === 'running') return outcome;
  const failed = outcome.kind === 'refused' || outcome.record.state === 'failed' || outcome.record.state === 'rejected';
  return now - seen.at < (failed ? FAILURE_SHOWN_MS : OUTCOME_SHOWN_MS) ? outcome : null;
}

function newerOutcome(own: ActionOutcome | null, other: ActionOutcome | null): ActionOutcome | null {
  if (own === null) return other;
  if (other === null) return own;
  return other.press > own.press ? other : own;
}

function outcomeKey(outcome: ActionOutcome | null): string | null {
  if (outcome === null) return null;
  if (outcome.kind === 'refused') return `refused:${outcome.press}`;
  return `${outcome.record.id}:${outcome.record.state}`;
}
