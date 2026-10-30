import { createContext, useContext, useEffect, useRef, useState } from 'react';
import type { ReactNode } from 'react';
import type { Gate } from '../../daemon/src/snapshot.ts';
import type { GateChoice, Verdict } from './gateAnswer.ts';
import type { ActionOutcome } from './useActions.ts';
import { useActionsView } from './ui.tsx';

/** What the owner had on the card when they answered, so a refused answer comes back as it was. */
export type Draft = { choices: GateChoice[]; note: string; mode: Verdict | null };

/** One action the answer leads to: not sent yet, on its way to the daemon, refused, or started as a record. */
export type Step = { state: 'waiting' } | { state: 'sending' } | { state: 'refused'; message: string } | { state: 'started'; id: string } | { state: 'skipped' };

/** What the owner decided, as the card says it back ("Sent back"), and the message it sent. */
export type Said = { verb: string; message: string };

/**
 * A gate answered here. It stays on screen, with the actions it started, after the gate itself
 * leaves the snapshot. `merge` is a merge gate's PR merge, which starts no run.
 */
export type Answered = { gate: Gate; at: Date; draft: Draft; said: Said; merge: boolean; back: boolean; clear: Step; run: Step | null };

/** What the card sends: a gate clear with its message, or a merge. */
export type Decision = { kind: 'clear'; message: string; back: boolean; said: Said } | { kind: 'merge'; pr: number; said: Said };

/** One raising of a gate: a later gate on the same item is another instance, with no draft of its own. */
export const gateKey = (gate: Gate): string => `${gate.item}:${gate.raisedAt}`;

export type GateAnswers = {
  answered: Record<string, Answered>;
  /** Answers brought back after a failed clear, by `gateKey`. */
  drafts: Record<string, Draft>;
  answer: (gate: Gate, decision: Decision, draft: Draft) => void;
  retry: (entry: Answered) => void;
};

const stepOf = (outcome: ActionOutcome): Step => (outcome.kind === 'started' ? { state: 'started', id: outcome.record.id } : { state: 'refused', message: outcome.message });

const GateAnswersContext = createContext<GateAnswers | null>(null);

/**
 * The gates answered in this project, kept above the screens: a clear that finishes after the
 * owner leaves Gates still starts the item's run.
 */
export function GateAnswersProvider({ children }: { children: ReactNode }) {
  const actions = useActionsView();
  const [answered, setAnswered] = useState<Record<string, Answered>>({});
  const [drafts, setDrafts] = useState<Record<string, Draft>>({});
  const runsAsked = useRef(new Set<string>());

  const change = (item: string, update: (entry: Answered) => Answered): void => {
    setAnswered((all) => (all[item] === undefined ? all : { ...all, [item]: update(all[item]) }));
  };

  const answer = (gate: Gate, decision: Decision, draft: Draft): void => {
    runsAsked.current.delete(gate.item);
    setDrafts((all) => Object.fromEntries(Object.entries(all).filter(([key]) => key !== gateKey(gate))));
    const merge = decision.kind === 'merge';
    const back = decision.kind === 'clear' && decision.back;
    setAnswered((all) => ({ ...all, [gate.item]: { gate, at: new Date(), draft, said: decision.said, merge, back, clear: { state: 'sending' }, run: merge ? null : { state: 'waiting' } } }));
    const sent = decision.kind === 'merge'
      ? actions.run('pr.merge', { pr: String(decision.pr) })
      : actions.run('gate.clear', decision.back ? { item: gate.item, message: decision.message, back: 'true' } : { item: gate.item, message: decision.message });
    void sent.then((outcome) => change(gate.item, (entry) => ({ ...entry, clear: stepOf(outcome) })));
  };

  const retry = (entry: Answered): void => {
    setDrafts((all) => ({ ...all, [gateKey(entry.gate)]: entry.draft }));
    setAnswered((all) => Object.fromEntries(Object.entries(all).filter(([item]) => item !== entry.gate.item)));
  };

  // The run starts once the gate is cleared, never before, or next.sh would find it still raised.
  useEffect(() => {
    for (const entry of Object.values(answered)) {
      const item = entry.gate.item;
      if (entry.run?.state !== 'waiting' || entry.clear.state === 'sending' || runsAsked.current.has(item)) continue;
      const cleared = entry.clear.state === 'started' ? actions.records.find((record) => record.id === (entry.clear as { id: string }).id) : undefined;
      if (entry.clear.state === 'started' && (cleared === undefined || cleared.state === 'running')) continue;
      runsAsked.current.add(item);
      if (cleared === undefined || cleared.state !== 'done' || cleared.exitCode !== 0) {
        change(item, (current) => ({ ...current, run: { state: 'skipped' } }));
        continue;
      }
      change(item, (current) => ({ ...current, run: { state: 'sending' } }));
      void actions.run('run.start', { item }).then((outcome) => change(item, (current) => ({ ...current, run: stepOf(outcome) })));
    }
  }, [answered, actions]);

  return <GateAnswersContext.Provider value={{ answered, drafts, answer, retry }}>{children}</GateAnswersContext.Provider>;
}

export function useGateAnswers(): GateAnswers {
  const answers = useContext(GateAnswersContext);
  if (answers === null) throw new Error('useGateAnswers needs a GateAnswersProvider above it');
  return answers;
}
