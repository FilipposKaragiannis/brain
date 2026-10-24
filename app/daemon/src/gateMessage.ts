import type { GateQuestion } from './snapshot.ts';

/**
 * Gate messages from the agents list numbered questions, each followed by `Recommended: ...`.
 * The parser turns that shape into decision-card questions. A message without numbering is one
 * question with no recommendation. Nothing is lost: the raw message stays on the gate.
 */
const QUESTION_START = /(?:^|\n)\s*(\d+)\.\s+/g;
const RECOMMENDED = /\n?\s*Recommended:\s*/i;

export function parseGateQuestions(message: string): GateQuestion[] {
  const starts = [...message.matchAll(QUESTION_START)];
  if (starts.length === 0) return [singleQuestion(message)];
  const questions: GateQuestion[] = [];
  starts.forEach((match, index) => {
    const bodyStart = match.index + match[0].length;
    const bodyEnd = index + 1 < starts.length ? starts[index + 1]!.index : message.length;
    const body = message.slice(bodyStart, bodyEnd).trim();
    questions.push({ number: Number(match[1]), ...splitRecommendation(body) });
  });
  return questions;
}

function singleQuestion(message: string): GateQuestion {
  return { number: 1, ...splitRecommendation(message.trim()) };
}

function splitRecommendation(body: string): { text: string; recommended: string | null } {
  const match = RECOMMENDED.exec(body);
  if (match === null) return { text: body, recommended: null };
  return { text: body.slice(0, match.index).trim(), recommended: body.slice(match.index + match[0].length).trim() };
}
