import { expect, test } from 'vitest';
import { composeGateMessage, recommendedAnswers } from '../src/gateAnswer.ts';

test('QuestionsWithRecommendations_PrefillTheAnswers', () => {
  const answers = recommendedAnswers([
    { number: 1, text: 'Keep the softer Rookie?', recommended: 'keep' },
    { number: 2, text: 'Anything else?', recommended: null },
  ]);
  expect(answers, 'because the card opens on the agent\'s recommendation and leaves the rest blank').toEqual([{ number: 1, answer: 'keep' }, { number: 2, answer: '' }]);
});

test('AnswersAndNote_NumberedLinesThenTheNote', () => {
  const message = composeGateMessage([{ number: 1, answer: '(a)' }, { number: 3, answer: ' yes ' }], 'Ship it after the rerun.');
  expect(message, 'because gate.clear posts the numbered answers one per line, then the free text').toBe('1. (a)\n3. yes\nShip it after the rerun.');
});

test('BlankAnswerAndNoNote_LeftOut', () => {
  const message = composeGateMessage([{ number: 1, answer: 'keep' }, { number: 2, answer: '  ' }], '');
  expect(message, 'because an empty line tells the agent nothing').toBe('1. keep');
});
