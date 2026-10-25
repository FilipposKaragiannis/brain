import { useState } from 'react';
import type { Gate, Snapshot } from '../../../daemon/src/snapshot.ts';
import { ItemLink } from '../links.tsx';
import { Age } from '../clock.tsx';
import { composeGateMessage, recommendedAnswers } from '../gateAnswer.ts';
import type { GateAnswer } from '../gateAnswer.ts';
import { routeHash } from '../route.ts';
import { actionStateLabel } from '../actions.ts';
import { actionRecordTone, pullTone } from '../status.ts';
import { GATE_KINDS } from '../words.ts';
import { Chip, Empty, Module, SourceFreshness, useActionsView } from '../ui.tsx';

export function Gates({ snapshot, selected }: { snapshot: Snapshot; selected: string | null }) {
  const gates = [...snapshot.gates].sort((left, right) => right.ageSeconds - left.ageSeconds);
  const current = selected === null ? gates[0] : gates.find((gate) => gate.item === selected);
  const projectId = snapshot.project.id;
  return (
    <div className="screen">
      <div className="columns">
        <Module className="gate-list" title="Waiting gates" aside={<span className="muted">{gates.length} waiting</span>} footer={<SourceFreshness name="files" freshness={snapshot.sources.files} />}>
          {gates.length === 0 ? <Empty>No gate waits on you.</Empty> : (
            <ul className="list">
              {gates.map((gate) => (
                <li key={gate.item}>
                  <a className={gate.item === current?.item ? 'list-row selected' : 'list-row'} href={routeHash({ projectId, screen: 'gates', detail: gate.item })}>
                    <Chip tone="needs-you">{gate.gate}</Chip>
                    <span className="mono">{gate.item}</span>
                    <span className={gate.overdue ? 'age-cell overdue' : 'age-cell'}><Age seconds={gate.ageSeconds} takenAt={snapshot.takenAt} />{gate.overdue ? ' · overdue' : ''}</span>
                  </a>
                </li>
              ))}
            </ul>
          )}
        </Module>
        {current !== undefined && <DecisionCard key={`${current.item}:${current.raisedAt}`} gate={current} snapshot={snapshot} />}
        {current === undefined && selected !== null && (
          <Module className="decision-card" title={<span className="mono">{selected}</span>} aside={null} footer={<SourceFreshness name="files" freshness={snapshot.sources.files} />}>
            <Empty>That gate was cleared. {gates.length > 0 ? 'Pick another from the list.' : 'Nothing else waits on you.'}</Empty>
          </Module>
        )}
      </div>
    </div>
  );
}

/** One gate as a decision: its questions with the recommendations filled in, a note, and Answer. */
export function DecisionCard({ gate, snapshot }: { gate: Gate; snapshot: Snapshot }) {
  const actions = useActionsView();
  const [answers, setAnswers] = useState<GateAnswer[]>(() => recommendedAnswers(gate.questions));
  const [note, setNote] = useState('');
  const title = snapshot.items.find((item) => item.id === gate.item)?.title ?? '';
  const args = { item: gate.item };
  const busy = actions.busy('gate.clear', args);
  const outcome = actions.outcome('gate.clear', args);
  const answer = (): void => { void actions.run('gate.clear', { item: gate.item, message: composeGateMessage(answers, note) }); };
  const setAnswer = (number: number, text: string): void => setAnswers((current) => current.map((entry) => (entry.number === number ? { number, answer: text } : entry)));
  return (
    <Module className="decision-card" title={<><Chip tone="needs-you">{gate.gate}</Chip> <ItemLink id={gate.item} pages={snapshot} /> {title}</>}
      aside={<span className={gate.overdue ? 'overdue' : 'muted'}>waiting <Age seconds={gate.ageSeconds} takenAt={snapshot.takenAt} />{gate.overdue ? ' · overdue' : ''}</span>}
      footer={<><span className="muted">{gate.worktree ?? 'no worktree'} · raised by {gate.host}</span><SourceFreshness name="files" freshness={snapshot.sources.files} /></>}>
      {GATE_KINDS[gate.gate] !== undefined && <p className="module-help gate-kind">{GATE_KINDS[gate.gate]}</p>}
      {gate.pull !== null && <GatePull pull={gate.pull} />}
      <form className="decision" onSubmit={(event) => { event.preventDefault(); answer(); }}>
        {gate.questions.map((question) => (
          <fieldset key={question.number} className="question">
            <legend>{question.number}.</legend>
            <p className="question-text">{question.text}</p>
            <label className="field">
              <span>{question.recommended === null ? 'Answer' : 'Answer (recommended filled in)'}</span>
              <textarea rows={3} value={answers.find((entry) => entry.number === question.number)?.answer ?? ''} onChange={(event) => setAnswer(question.number, event.target.value)} />
            </label>
          </fieldset>
        ))}
        <label className="field">
          <span>Note for the agent</span>
          <textarea rows={2} placeholder="Optional." value={note} onChange={(event) => setNote(event.target.value)} />
        </label>
        <div className="decision-actions">
          <button type="submit" className="button primary" disabled={busy}>{busy ? 'Answering…' : 'Answer'}</button>
          {outcome?.kind === 'refused' && <span className="chip tone-failing">{outcome.message}</span>}
          {outcome?.kind === 'started' && <Chip tone={actionRecordTone(outcome.record)}>{actionStateLabel(outcome.record)}</Chip>}
          <span className="muted">gate.clear {gate.item}</span>
        </div>
      </form>
    </Module>
  );
}

function GatePull({ pull }: { pull: NonNullable<Gate['pull']> }) {
  const threads = pull.unresolvedThreads;
  return (
    <div className="gate-pull">
      <div className="gate-pull-line">
        <a className="mono" href={pull.url} target="_blank" rel="noreferrer">PR #{pull.number}</a>
        <Chip tone={pullTone(pull.state)}>{pull.state}</Chip>
        <span className={threads > 0 ? 'tone-needs-you threads strong' : 'muted'}>{threads} unresolved review {threads === 1 ? 'thread' : 'threads'}</span>
      </div>
      {threads > 0 && <p className="muted">The comments job addresses threads; {threads === 1 ? 'this one is' : 'these are'} still open.</p>}
    </div>
  );
}
