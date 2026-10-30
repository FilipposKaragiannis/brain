import { expect, test } from 'vitest';
import { choiceAnswers, composeGateMessage, gateAsk, gateBrief, initialChoices, recommendedAnswers, verdictMessage } from '../src/gateAnswer.ts';

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

test('MessageWithQuestions_BriefIsTheTextBeforeThem', () => {
  expect(gateBrief('Why I stopped.\n1. Which way? Recommended: left'), 'because the lines before question 1 explain the gate').toEqual({ brief: 'Why I stopped.', numbered: true });
});

test('MessageWithNoNumberedLine_AllOfItIsTheBrief', () => {
  expect(gateBrief(' Sign off or list what feels wrong. '), 'because a message that asks nothing numbered is one thing to answer').toEqual({ brief: 'Sign off or list what feels wrong.', numbered: false });
});

test('Choices_RecommendationWhereThereIsOne', () => {
  const questions = [{ number: 1, text: 'Keep?', recommended: 'keep' }, { number: 2, text: 'Else?', recommended: null }];
  const choices = initialChoices(questions).map((choice) => (choice.number === 2 ? { ...choice, other: 'no' } : choice));
  expect(choiceAnswers(questions, choices), 'because a picked recommendation answers with its text and the rest with what the owner typed').toEqual([{ number: 1, answer: 'keep' }, { number: 2, answer: 'no' }]);
});

test('VerdictApprove_ShortMessageNoBack', () => {
  expect(verdictMessage('approve', 'ignored'), 'because a plain approval needs no notes').toEqual({ message: 'Approved.', back: false });
});

test('VerdictApproveWithNotes_NotesAfterTheApproval', () => {
  expect(verdictMessage('approve-notes', '  Keep it small. ').message, 'because the agent reads the notes in its next brief').toBe('Approved, with these notes:\n\nKeep it small.');
});

test('VerdictSendBackOrReport_TheNotesAloneAndBack', () => {
  expect(verdictMessage('send-back', 'Add a rollback.'), 'because gate.sh --back records the notes as the answer').toEqual({ message: 'Add a rollback.', back: true });
  expect(verdictMessage('report', 'Feels slow.').back, 'because a reported problem sends the build back').toBe(true);
});

test('BriefLedByABoldLine_ThatLineIsTheAsk', () => {
  expect(gateAsk('**Approve the plan.**\n\n- Three slices.'), 'because gates lead with the decision in bold').toEqual({ ask: 'Approve the plan.', rest: '- Three slices.' });
});

test('BriefWithNoBoldFirstLine_NoAsk', () => {
  expect(gateAsk('Re-sized M -> L. **Size is L.**'), 'because bold text later in a line is not the ask').toEqual({ ask: null, rest: 'Re-sized M -> L. **Size is L.**' });
});
