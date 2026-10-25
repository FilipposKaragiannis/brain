import assert from 'node:assert/strict';
import { test } from 'node:test';
import { parseGateQuestions } from '../src/gateMessage.ts';

const NUMBERED = '1. Keep the old name? Recommended: yes, because callers depend on it.\n2. Split the type?\nRecommended: no.\n3. Anything else?';

test('NumberedMessage_OneQuestionPerNumber', () => {
  const questions = parseGateQuestions(NUMBERED);
  assert.deepEqual(questions.map((question) => question.number), [1, 2, 3], 'because each numbered line is one decision');
});

test('RecommendedInline_SplitFromQuestion', () => {
  const [first] = parseGateQuestions(NUMBERED);
  assert.equal(first?.text, 'Keep the old name?', 'because the question ends where the recommendation starts');
  assert.equal(first?.recommended, 'yes, because callers depend on it.', 'because the recommendation is the preselected answer');
});

test('RecommendedOnNextLine_StillFound', () => {
  assert.equal(parseGateQuestions(NUMBERED)[1]?.recommended, 'no.', 'because agents put the recommendation on its own line too');
});

test('NoRecommendation_IsNull', () => {
  assert.equal(parseGateQuestions(NUMBERED)[2]?.recommended, null, 'because a missing recommendation must not preselect anything');
});

test('PlainMessage_SingleQuestion', () => {
  const questions = parseGateQuestions('The plan is ready for approval.');
  assert.equal(questions.length, 1, 'because an unnumbered gate is one yes-or-no decision');
  assert.equal(questions[0]?.text, 'The plan is ready for approval.', 'because the whole message is the question');
});
