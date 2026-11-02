import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { parseQuiz, parseQuizResult, readQuizzes } from '../src/quiz.ts';

const QUIZ = `<!-- flow:quiz -->
## Quiz for gh#7
1. What fires a shot now?
   a) A tap only
   b) A tap, or a release after a hold
   c) Only a release after a hold
   Because: a tap still fires a normal shot, and a release after a hold fires a charged one.
2. What happens when the hold
   passes 600 ms?
   a) The shot fires on its own b) The power caps at full c) The charge resets
   **Because:** the power is clamped at 1.0,
   so a longer hold adds nothing.
3. Why does the tap golden replay matter?
   a) It proves a tap still plays as before
   b) It proves the glow renders
<!-- answers: 1b 2b 3a -->
`;

test('ParseQuiz_WrittenQuiz_TitleQuestionsAndKeyRead', () => {
  const quiz = parseQuiz(QUIZ);
  assert.equal(quiz.title, 'Quiz for gh#7', 'because the heading names the quiz on the card');
  assert.deepEqual(quiz.questions.map((question) => question.number), [1, 2, 3], 'because every numbered line starts a question');
  assert.deepEqual(quiz.questions.map((question) => question.answer), ['b', 'b', 'a'], 'because the answers comment is the key');
});

test('ParseQuiz_ChoicesOnTheirOwnLinesOrSharingOne', () => {
  const [first, second] = parseQuiz(QUIZ).questions;
  assert.deepEqual(first?.choices, [{ key: 'a', text: 'A tap only' }, { key: 'b', text: 'A tap, or a release after a hold' }, { key: 'c', text: 'Only a release after a hold' }], 'because a choice per line is the format the skill asks for');
  assert.deepEqual(second?.choices.map((choice) => choice.text), ['The shot fires on its own', 'The power caps at full', 'The charge resets'], 'because an agent may still put the choices on one line');
  assert.equal(second?.text, 'What happens when the hold passes 600 ms?', 'because a question may run over two lines before its choices');
});

test('ParseQuiz_BecauseLine_BoldOrPlain_Continued_OrAbsent', () => {
  const [first, second, third] = parseQuiz(QUIZ).questions;
  assert.equal(first?.because, 'a tap still fires a normal shot, and a release after a hold fires a charged one.', 'because the justification is shown with the result');
  assert.equal(second?.because, 'the power is clamped at 1.0, so a longer hold adds nothing.', 'because a bold Because that runs on is one justification');
  assert.equal(third?.because, null, 'because a question with no Because line has none to show');
});

test('ParseQuiz_NoKeyForAQuestion_AnswerNull', () => {
  const quiz = parseQuiz('1. One?\n   a) x\n   b) y\n<!-- answers: 2a -->');
  assert.equal(quiz.questions[0]?.answer, null, 'because a question the key leaves out can never be right, and the page must not pretend otherwise');
});

test('ParseQuiz_NoNumberedLine_NoQuestions', () => {
  assert.deepEqual(parseQuiz('## Quiz\nNothing here.').questions, [], 'because a page with no quiz shows no quiz');
});

test('ParseQuizResult_ValidFile_ReadAsWritten', () => {
  const result = parseQuizResult('{"given": {"1": "b", "2": "a"}, "right": 1, "total": 2, "passed": false, "item": "gh#7", "at": "2026-10-24T09:30:00Z"}');
  assert.deepEqual(result, { at: '2026-10-24T09:30:00Z', right: 1, total: 2, passed: false, given: { '1': 'b', '2': 'a' } }, 'because the card shows the last try and the letters given');
});

test('ParseQuizResult_MalformedJson_Null', () => {
  assert.equal(parseQuizResult('not json'), null, 'because a broken file is no result');
});

test('ParseQuizResult_MissingNumbers_Null', () => {
  assert.equal(parseQuizResult('{"right": "one"}'), null, 'because a result without its numbers is no result');
});

/** The quizzes read from a claimed worktree, a missing root and the main root, in that order: gh-7 in
 * both real roots (a last try beside the claimed one), gh-8 only in main, and gh-9 with no question. */
async function readFixtureQuizzes(): Promise<Awaited<ReturnType<typeof readQuizzes>>> {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'console-quiz-'));
  try {
    const claimed = path.join(dir, 'wt');
    const main = path.join(dir, 'main');
    for (const [root, slug, text] of [[claimed, 'gh-7', QUIZ], [main, 'gh-7', '1. Old copy?\n   a) x b) y\n<!-- answers: 1a -->'], [main, 'gh-8', '1. Other?\n   a) x b) y\n<!-- answers: 1b -->'], [main, 'gh-9', 'no quiz here']] as const) {
      mkdirSync(path.join(root, '.flow', 'reports', slug), { recursive: true });
      writeFileSync(path.join(root, '.flow', 'reports', slug, 'quiz.md'), text);
    }
    writeFileSync(path.join(claimed, '.flow', 'reports', 'gh-7', 'quiz.json'), '{"given": {"1": "b"}, "right": 1, "total": 3, "passed": false, "at": "2026-10-24T09:30:00Z"}');
    return await readQuizzes([claimed, path.join(dir, 'missing'), main]);
  } finally { rmSync(dir, { recursive: true, force: true }); }
}

test('ReadQuizzes_SameSlugInTwoRoots_FirstRootWins', async () => {
  const quizzes = await readFixtureQuizzes();
  assert.equal(quizzes['gh-7']?.questions.length, 3, 'because the claimed worktree holds the quiz the explain step wrote, as steward.sh reports looks');
});

test('ReadQuizzes_QuizWithNoQuestions_LeftOut', async () => {
  const quizzes = await readFixtureQuizzes();
  assert.equal(quizzes['gh-9'], undefined, 'because a quiz.md with no question is no quiz');
});

test('ReadQuizzes_MissingRoot_Skipped', async () => {
  const quizzes = await readFixtureQuizzes();
  assert.equal(quizzes['gh-8']?.questions.length, 1, 'because a missing root is skipped and the roots after it are still read');
});

test('ReadQuizzes_ResultBesideTheQuiz_RidesAlong', async () => {
  const quizzes = await readFixtureQuizzes();
  assert.equal(quizzes['gh-7']?.result?.right, 1, 'because the result beside the quiz is the last try');
});

test('ReadQuizzes_UntriedQuiz_ResultNull', async () => {
  const quizzes = await readFixtureQuizzes();
  assert.equal(quizzes['gh-8']?.result, null, 'because an untried quiz has no result');
});
