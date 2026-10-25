import type { GateQuestion } from '../../daemon/src/snapshot.ts';

export type GateAnswer = { number: number; answer: string };

/** The answers the card starts with: each question's recommendation, or blank. */
export function recommendedAnswers(questions: GateQuestion[]): GateAnswer[] {
  return questions.map((question) => ({ number: question.number, answer: question.recommended ?? '' }));
}

/** The message `gate.clear` sends: the numbered answers one per line, then the free text. */
export function composeGateMessage(answers: GateAnswer[], note: string): string {
  const lines = answers.filter((entry) => entry.answer.trim() !== '').map((entry) => `${entry.number}. ${entry.answer.trim()}`);
  if (note.trim() !== '') lines.push(note.trim());
  return lines.join('\n');
}
