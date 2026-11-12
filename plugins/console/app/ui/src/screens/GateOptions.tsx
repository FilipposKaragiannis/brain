import { useState } from 'react';
import type { Gate, GateOption } from '../../../daemon/src/snapshot.ts';
import { optionAnswer } from '../gateAnswers.tsx';
import type { Decision, Draft } from '../gateAnswers.tsx';
import { Markdown } from '../Markdown.tsx';

/** The decision one option button sends, with the note the owner typed going along with it. */
function optionDecision(number: number, option: GateOption, note: string): Decision {
  return { kind: 'option', number, text: option.text, note, said: { verb: `Answered with option ${number}`, message: optionAnswer(option.text, note) } };
}

/**
 * The answers the agent offered, one button each with the recommended one marked, and a free-text
 * field: typed words go with a picked option as its note, or are sent alone as the owner's answer.
 */
export function OptionsForm({ gate, hint, draft, onAnswer }: { gate: Gate; hint: string; draft: Draft | null; onAnswer: (decision: Decision, draft: Draft) => void }) {
  const [note, setNote] = useState(draft?.note ?? '');
  const kept: Draft = { choices: [], note, mode: null };
  const sendOwn = (): void => onAnswer({ kind: 'clear', message: note.trim(), back: false, said: { verb: 'Answered', message: note.trim() } }, kept);
  return (
    <form className="decision" onSubmit={(event) => { event.preventDefault(); if (note.trim() !== '') sendOwn(); }}>
      <fieldset className="question">
        <legend>Pick an answer</legend>
        <ol className="option-list">
          {gate.options.map((option, index) => {
            const number = index + 1;
            return (
              <li key={number} className={option.recommended ? 'option-choice recommended-choice' : 'option-choice'}>
                <button type="button" className={option.recommended ? 'button primary' : 'button'} onClick={() => onAnswer(optionDecision(number, option, note), kept)}>
                  {number}. {option.label}
                </button>
                <span className="option-text">{option.recommended && <span className="recommended">Recommended · </span>}<Markdown text={option.text} /></span>
              </li>
            );
          })}
        </ol>
      </fieldset>
      <label className="field">
        <span>A note with the option, or your own answer</span>
        <textarea rows={2} placeholder="Optional with an option." value={note} onChange={(event) => setNote(event.target.value)} />
      </label>
      <div className="decision-actions">
        <button type="submit" className="button" disabled={note.trim() === ''}>Send my own answer</button>
        <span className="muted mono">{hint}</span>
      </div>
    </form>
  );
}
