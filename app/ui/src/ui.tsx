import { createContext, useContext } from 'react';
import type { ReactNode } from 'react';
import type { Freshness, SourceName } from '../../daemon/src/snapshot.ts';
import type { ActionKind } from './actions.ts';
import { Since } from './clock.tsx';
import { actionTone, freshnessTone } from './status.ts';
import type { Tone } from './status.ts';
import type { ActionsView } from './useActions.ts';

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

/** A button that runs one action, stays disabled while that action runs, and shows how it ended. */
export function ActionButton({ kind, args, label, primary }: { kind: ActionKind; args: Record<string, string>; label: string; primary: boolean }) {
  const actions = useActionsView();
  const busy = actions.busy(kind, args);
  const outcome = actions.outcome(kind, args);
  return (
    <span className="action">
      <button type="button" className={primary ? 'button primary' : 'button'} disabled={busy} onClick={() => { void actions.run(kind, args); }}>
        {busy ? `${label}…` : label}
      </button>
      {outcome?.kind === 'refused' && <span className="chip tone-failing" title={outcome.message}>{outcome.message}</span>}
      {outcome?.kind === 'started' && <Chip tone={actionTone(outcome.record.state)}>{outcome.record.state}{outcome.record.exitCode !== null && outcome.record.exitCode !== 0 ? ` (exit ${outcome.record.exitCode})` : ''}</Chip>}
    </span>
  );
}
