import type { GateQuestion } from '../../daemon/src/snapshot.ts';

export type GateAnswer = { number: number; answer: string };

/** How one question is answered: the agent's recommendation, or the owner's own words. */
export type GateChoice = { number: number; pick: 'recommended' | 'other'; other: string };

/** The answers the card starts with: each question's recommendation, or blank. */
export function recommendedAnswers(questions: GateQuestion[]): GateAnswer[] {
  return questions.map((question) => ({ number: question.number, answer: question.recommended ?? '' }));
}

/** The choices the card starts with: the recommendation where there is one, else the owner's words. */
export function initialChoices(questions: GateQuestion[]): GateChoice[] {
  return questions.map((question) => ({ number: question.number, pick: question.recommended === null ? 'other' : 'recommended', other: '' }));
}

/** The answer each choice stands for: the recommendation's text, or what the owner typed. */
export function choiceAnswers(questions: GateQuestion[], choices: GateChoice[]): GateAnswer[] {
  return questions.map((question) => {
    const choice = choices.find((entry) => entry.number === question.number);
    const answer = choice?.pick === 'recommended' ? question.recommended ?? '' : choice?.other ?? '';
    return { number: question.number, answer };
  });
}

/** The message `gate.clear` sends: the numbered answers one per line, then the free text. */
export function composeGateMessage(answers: GateAnswer[], note: string): string {
  const lines = answers.filter((entry) => entry.answer.trim() !== '').map((entry) => `${entry.number}. ${entry.answer.trim()}`);
  if (note.trim() !== '') lines.push(note.trim());
  return lines.join('\n');
}

const NUMBERED_LINE = /^\s*\d+[.)](?:\s|$)/m;

/**
 * The part of a gate message that is not a question: the text before the first numbered line, or
 * the whole message when it has none. `numbered` says whether the message asks numbered questions
 * at all; without them the card shows the message and one answer box, not a question "1".
 */
export function gateBrief(message: string): { brief: string; numbered: boolean } {
  const start = NUMBERED_LINE.exec(message);
  if (start === null) return { brief: message.trim(), numbered: false };
  return { brief: message.slice(0, start.index).trim(), numbered: true };
}

/** What the owner decided on a gate that asks for a verdict, not for answers. */
export type Verdict = 'approve' | 'approve-notes' | 'send-back' | 'sign-off' | 'report';

/**
 * The message `gate.clear` sends for a verdict, and whether it sends the work back. Send back and
 * report problems run the gate's step again, with the notes in its brief.
 */
export function verdictMessage(verdict: Verdict, notes: string): { message: string; back: boolean } {
  const text = notes.trim();
  switch (verdict) {
    case 'approve': return { message: 'Approved.', back: false };
    case 'approve-notes': return { message: `Approved, with these notes:\n\n${text}`, back: false };
    case 'sign-off': return { message: 'Signed off. It feels right.', back: false };
    case 'send-back': case 'report': return { message: text, back: true };
  }
}

const ASK_LINE = /^\s*\*\*(.+?)\*\*\s*(?:\n|$)/;

/**
 * The bold first line a gate message leads with, the decision it asks for, apart from the rest.
 * `ask` is null for a message written before gates led with one.
 */
export function gateAsk(brief: string): { ask: string | null; rest: string } {
  const match = ASK_LINE.exec(brief);
  if (match === null) return { ask: null, rest: brief };
  return { ask: match[1]!.trim(), rest: brief.slice(match[0].length).trim() };
}
