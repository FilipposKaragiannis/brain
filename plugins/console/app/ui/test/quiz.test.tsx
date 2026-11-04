import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import type { Gate, PullRequest, Quiz } from '../../daemon/src/snapshot.ts';
import { Gates } from '../src/screens/Gates.tsx';
import { Pulls } from '../src/screens/Pulls.tsx';
import { gradeQuiz, quizAnswers, CHECK_ANSWERS, TAKE_QUIZ } from '../src/Quiz.tsx';
import type { ActionRecord } from '../src/actions.ts';
import { actionRecord, FakeDaemon, HTTP_ACCEPTED, snapshotAt, TAKEN_AT, waitingGate } from './fakeDaemon.tsx';

afterEach(cleanup);

const QUIZ: Quiz = {
  file: '/p-wt/project-wt-2/.flow/reports/gh-7/quiz.md',
  title: 'Quiz for gh#7',
  questions: [
    { number: 1, text: 'What fires a shot now?', choices: [{ key: 'a', text: 'A tap only' }, { key: 'b', text: 'A tap, or a release after a hold' }], answer: 'b', because: 'a tap still fires a normal shot, and a release after a hold fires a charged one.' },
    { number: 2, text: 'What happens past 600 ms?', choices: [{ key: 'a', text: 'The shot fires on its own' }, { key: 'b', text: 'The power caps at full' }], answer: 'b', because: 'the power is clamped at 1.0.' },
  ],
  result: null,
};
const FAILED: Quiz = { ...QUIZ, result: { at: '2026-10-24T09:30:00Z', right: 1, total: 2, passed: false, given: { '1': 'b', '2': 'a' } } };
const PASSED: Quiz = { ...QUIZ, result: { at: '2026-10-24T09:30:00Z', right: 2, total: 2, passed: true, given: { '1': 'b', '2': 'b' } } };
const DRAFT_PULL = { number: 90, url: 'https://github.com/owner/project/pull/90', state: 'draft' as const, unresolvedThreads: 0 };

function recordingDaemon(): { daemon: FakeDaemon; posted: Array<{ kind: string; args: Record<string, string> }> } {
  const daemon = new FakeDaemon();
  const posted: Array<{ kind: string; args: Record<string, string> }> = [];
  daemon.answer('POST', '/api/projects/project/actions', (body) => {
    const action = body as { kind: ActionRecord['kind']; args: Record<string, string> };
    posted.push(action);
    return { status: HTTP_ACCEPTED, body: { action: { ...actionRecord(`a${posted.length}`, 'running', action.args), kind: action.kind } } };
  });
  return { daemon, posted };
}

function renderGate(gate: Gate, daemon = new FakeDaemon()): void {
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><Gates snapshot={{ ...snapshotAt(TAKEN_AT, 1), gates: [gate] }} selected={gate.item} /></Wrapper>);
}

function pull(change: Partial<PullRequest>): PullRequest {
  return {
    number: 90, title: 'Charge shot', url: DRAFT_PULL.url, branch: 'flow/gh-7', base: 'main', author: 'owner', draft: true, state: 'draft',
    checks: { passed: 0, failed: 0, pending: 0 }, checkRuns: [], head: null, autoMerge: null, reviewDecision: null, unresolvedThreads: 0, mergeable: 'MERGEABLE', mergeState: 'CLEAN', item: 'gh#7', worktree: null,
    createdAt: TAKEN_AT, updatedAt: TAKEN_AT, ageSeconds: 600, idleSeconds: 60, review: null, quiz: null, ...change,
  };
}

function renderPull(entry: PullRequest, daemon = new FakeDaemon()): void {
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><Pulls snapshot={{ ...snapshotAt(TAKEN_AT, 0), pulls: [entry] }} /></Wrapper>);
}

const quizPanel = (): HTMLElement => screen.getByRole('region', { name: 'Quiz' });

async function press(name: string): Promise<void> {
  await act(async () => { fireEvent.click(screen.getByRole('button', { name })); });
}

test('QuizAnswers_LetterPerQuestionNumber_JoinedInQuestionOrder', () => {
  expect(quizAnswers(QUIZ, { 2: 'a', 1: 'b' }), 'because quiz.sh takes the letters with their question numbers').toBe('1b 2a');
});

test('GradeQuiz_EveryQuestionRight_Passes', () => {
  expect(gradeQuiz(QUIZ, { 1: 'b', 2: 'b' }).passed, 'because every question right is a pass').toBe(true);
});

test('GradeQuiz_AWrongAnswer_CountedAndFails', () => {
  expect(gradeQuiz(QUIZ, { 1: 'b', 2: 'a' }), 'because one wrong is a fail with the count shown').toMatchObject({ right: 1, total: 2, passed: false });
});

test('GradeQuiz_QuestionWithNoKey_NeverRight', () => {
  const keyless: Quiz = { ...QUIZ, questions: [{ ...QUIZ.questions[0]!, answer: null }] };
  expect(gradeQuiz(keyless, { 1: 'b' }).passed, 'because a question the key leaves out cannot be right, as the flow grades it').toBe(false);
});

test('GateWithAnUntriedQuiz_OffersToTakeIt', () => {
  renderGate({ ...waitingGate('gh#7', 'merge'), quiz: QUIZ });
  expect(within(quizPanel()).getByRole('button', { name: TAKE_QUIZ }), 'because the quiz is taken here, not in a PR comment').not.toBeNull();
  expect(quizPanel().textContent, 'because the owner sees how much is asked of them').toMatch(/2 questions/);
  expect(quizPanel().textContent, 'because the owner sees what passing does').toMatch(/draft PR goes ready/);
  expect(screen.queryByText('quiz: 2 questions'), 'because the card head lists the quiz among its facts').not.toBeNull();
});

test('TakingTheQuiz_CheckWaitsForEveryAnswer_ThenPostsTheTry', async () => {
  const { daemon, posted } = recordingDaemon();
  renderGate({ ...waitingGate('gh#7', 'merge'), quiz: QUIZ }, daemon);
  await press(TAKE_QUIZ);
  const check = screen.getByRole('button', { name: CHECK_ANSWERS }) as HTMLButtonElement;
  expect(check.disabled, 'because a try with a question unanswered grades nothing').toBe(true);
  fireEvent.click(screen.getByRole('radio', { name: /A tap, or a release after a hold/ }));
  fireEvent.click(screen.getByRole('radio', { name: /The shot fires on its own/ }));
  expect(check.disabled, 'because every question has a letter now').toBe(false);
  await press(CHECK_ANSWERS);
  expect(posted, 'because the flow grades the same letters, keeps the result and marks the draft ready on a pass').toEqual([{ kind: 'quiz.answer', args: { item: 'gh#7', answers: '1b 2a' } }]);
});

test('ResultsAfterATry_MarkEachQuestionAndSayWhy', async () => {
  const { daemon } = recordingDaemon();
  renderGate({ ...waitingGate('gh#7', 'merge'), quiz: QUIZ }, daemon);
  await press(TAKE_QUIZ);
  fireEvent.click(screen.getByRole('radio', { name: /A tap, or a release after a hold/ }));
  fireEvent.click(screen.getByRole('radio', { name: /The shot fires on its own/ }));
  await press(CHECK_ANSWERS);
  const panel = quizPanel();
  expect(within(panel).getAllByLabelText('right').length, 'because the first answer was right').toBe(1);
  expect(within(panel).getAllByLabelText('wrong').length, 'because the second was wrong').toBe(1);
  expect(panel.textContent, 'because a wrong answer shows the right one').toMatch(/Right answer: b\) The power caps at full/);
  expect(panel.textContent, 'because the Because line is what the owner learns from').toMatch(/Because the power is clamped at 1\.0\./);
  expect(panel.textContent, 'because the score is said').toMatch(/1 of 2 right/);
  expect(within(panel).getByRole('button', { name: 'Take it again' }), 'because a failed try can be retaken').not.toBeNull();
});

test('APassingTry_SaysTheDraftGoesReady', async () => {
  const { daemon } = recordingDaemon();
  renderGate({ ...waitingGate('gh#7', 'merge'), quiz: QUIZ }, daemon);
  await press(TAKE_QUIZ);
  fireEvent.click(screen.getByRole('radio', { name: /A tap, or a release after a hold/ }));
  fireEvent.click(screen.getByRole('radio', { name: /The power caps at full/ }));
  await press(CHECK_ANSWERS);
  expect(quizPanel().textContent, 'because the score of a pass is said').toMatch(/Passed: 2 of 2/);
  expect(quizPanel().textContent, 'because passing is what frees the PR').toMatch(/draft PR goes ready/);
  expect(within(quizPanel()).queryByRole('button', { name: 'Take it again' }), 'because a pass needs no retake').toBeNull();
});

test('QuizWithALastFailedTry_SummaryAndSeeResults', async () => {
  renderGate({ ...waitingGate('gh#7', 'merge'), quiz: FAILED });
  expect(quizPanel().textContent, 'because the last try the flow kept is shown').toMatch(/1 of 2 right at/);
  await press('See results');
  expect(quizPanel().textContent, 'because the kept letters grade like a fresh try').toMatch(/Right answer: b\) The power caps at full/);
  expect(within(quizPanel()).getByRole('button', { name: 'Take it again' }), 'because the owner can try again from the results').not.toBeNull();
});

test('QuizPassed_CardHeadSaysSo', () => {
  renderGate({ ...waitingGate('gh#7', 'merge'), quiz: PASSED });
  expect(screen.queryByText('quiz passed'), 'because a passed quiz is a fact of the gate, not a task').not.toBeNull();
  expect(within(quizPanel()).queryByRole('button', { name: TAKE_QUIZ }), 'because a passed quiz offers a retake, not a first take').toBeNull();
});

test('MergeGateOnADraftWithAQuizPending_SaysPassTheQuiz', () => {
  renderGate({ ...waitingGate('gh#7', 'merge'), pull: DRAFT_PULL, quiz: QUIZ });
  expect(screen.queryByText(/PR #90 is a draft until you pass the quiz above/), 'because the quiz is what holds the draft, and it sits on this card').not.toBeNull();
});

test('PullCardOnADraftWithAQuiz_OffersItAndSaysWhyMergeWaits', () => {
  renderPull(pull({ quiz: QUIZ }));
  const card = screen.getByRole('region', { name: 'PR #90' });
  expect(within(card).getByRole('button', { name: TAKE_QUIZ }), 'because the PR card is the other place the owner looks for the quiz').not.toBeNull();
  expect(card.textContent, 'because the draft state is explained by the quiz, not by GitHub').toMatch(/A draft until you pass the quiz above/);
});

test('PullCardWithNoQuiz_NoPanel', () => {
  renderPull(pull({}));
  expect(screen.queryByRole('region', { name: 'Quiz' }), 'because a PR with no quiz has nothing to take').toBeNull();
  expect(screen.getByRole('region', { name: 'PR #90' }).textContent, 'because a plain draft still says how to go ready').toMatch(/A draft cannot be merged/);
});
