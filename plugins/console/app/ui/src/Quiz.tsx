import { useState } from 'react';
import type { Quiz, QuizQuestion } from '../../daemon/src/snapshot.ts';
import { actionStateLabel } from './actions.ts';
import { clockTime } from './clock.tsx';
import { Markdown } from './Markdown.tsx';
import { actionRecordTone } from './status.ts';
import type { Tone } from './status.ts';
import { Chip, useActionsView } from './ui.tsx';

/*
 * The owner's quiz on an item's change, as the explain step wrote it: taken here, on the Gates
 * card and the PR card, instead of in a PR comment nobody answers. The page grades a try itself
 * for the instant result, then runs `quiz.answer`, where the flow keeps the result beside the
 * quiz and marks the draft PR ready on a pass. Every question shows its Because line with the
 * result, so a wrong answer teaches something.
 */

/** The letter picked per question number. */
export type Given = Record<number, string>;

/** How one try went, question by question. */
export type Graded = { right: number; total: number; passed: boolean; perQuestion: Array<{ question: QuizQuestion; given: string | null; right: boolean }> };

/** The answers as `quiz.sh answer` takes them: `1b 2a 3c`, in question order. */
export function quizAnswers(quiz: Quiz, given: Given): string {
  return quiz.questions.filter((question) => given[question.number] !== undefined).map((question) => `${question.number}${given[question.number]}`).join(' ');
}

/** The grade the flow's grader gives the same letters: every question right passes; a question with no key is never right. */
export function gradeQuiz(quiz: Quiz, given: Given): Graded {
  const perQuestion = quiz.questions.map((question) => {
    const letter = given[question.number] ?? null;
    return { question, given: letter, right: letter !== null && question.answer !== null && letter === question.answer };
  });
  const right = perQuestion.filter((entry) => entry.right).length;
  return { right, total: perQuestion.length, passed: perQuestion.length > 0 && right === perQuestion.length, perQuestion };
}

/** The letters of the last try the flow kept, by question number. */
export function lastGiven(quiz: Quiz): Given | null {
  if (quiz.result === null) return null;
  return Object.fromEntries(Object.entries(quiz.result.given).map(([number, letter]) => [Number(number), letter]));
}

type Mode = 'summary' | 'taking' | 'results';

/** What the panel says passing does, the same words on both pages. */
export const PASS_HELP = 'Pass it and the draft PR goes ready for review.';
export const TAKE_QUIZ = 'Take the quiz';
export const CHECK_ANSWERS = 'Check my answers';

/** The quiz of one item: its state in a line, and the try or the results when opened. */
export function QuizPanel({ item, quiz }: { item: string; quiz: Quiz }) {
  const [mode, setMode] = useState<Mode>('summary');
  const [draft, setDraft] = useState<Given>({});
  const [shown, setShown] = useState<Given | null>(null);
  const actions = useActionsView();
  const outcome = actions.outcome('quiz.answer', { item });
  const total = quiz.questions.length;
  const last = quiz.result;
  const start = (): void => { setDraft({}); setMode('taking'); };
  const check = (): void => {
    setShown(draft);
    setMode('results');
    void actions.run('quiz.answer', { item, answers: quizAnswers(quiz, draft) });
  };
  const results = mode === 'results' ? (shown ?? lastGiven(quiz)) : null;
  return (
    <section className="quiz" aria-label="Quiz">
      <div className="quiz-line">
        <h3>{quiz.title ?? 'Quiz'}</h3>
        {last !== null && <Chip tone={last.passed ? 'running' : 'needs-you'}>{last.passed ? 'passed' : `${last.right} of ${last.total}`}</Chip>}
        <span className="muted">
          {last === null ? `${total} ${total === 1 ? 'question' : 'questions'} on this change. ${PASS_HELP}` : `${last.right} of ${last.total} right at ${clockTime(last.at)}.${last.passed ? '' : ` ${PASS_HELP}`}`}
        </span>
        {mode === 'summary' && (
          <span className="quiz-buttons">
            {last !== null && <button type="button" className="button" onClick={() => { setShown(null); setMode('results'); }}>See results</button>}
            <button type="button" className={last === null ? 'button primary' : 'button'} onClick={start}>{last === null ? TAKE_QUIZ : 'Take it again'}</button>
          </span>
        )}
      </div>
      {mode === 'taking' && <QuizForm item={item} quiz={quiz} draft={draft} onChange={setDraft} onCheck={check} onCancel={() => setMode('summary')} />}
      {results !== null && (
        <QuizResults
          graded={gradeQuiz(quiz, results)}
          live={shown !== null}
          note={outcome === null || shown === null ? null : outcome.kind === 'refused' ? { tone: 'failing' as const, text: `not recorded: ${outcome.message}` } : { tone: actionRecordTone(outcome.record), text: `recording ${actionStateLabel(outcome.record)}` }}
          onAgain={start}
          onClose={() => setMode('summary')}
        />
      )}
    </section>
  );
}

function QuizForm({ item, quiz, draft, onChange, onCheck, onCancel }: { item: string; quiz: Quiz; draft: Given; onChange: (given: Given) => void; onCheck: () => void; onCancel: () => void }) {
  const ready = quiz.questions.every((question) => draft[question.number] !== undefined);
  return (
    <form className="decision quiz-form" onSubmit={(event) => { event.preventDefault(); if (ready) onCheck(); }}>
      {quiz.questions.map((question) => (
        <fieldset key={question.number} className="question">
          <legend><span className="question-number">{question.number}.</span> <Markdown className="question-text" text={question.text} /></legend>
          {question.choices.map((choice) => (
            <label key={choice.key} className={draft[question.number] === choice.key ? 'option picked' : 'option'}>
              <input type="radio" name={`quiz-${item}-q${question.number}`} checked={draft[question.number] === choice.key} onChange={() => onChange({ ...draft, [question.number]: choice.key })} />
              <span className="option-text"><span className="mono muted">{choice.key})</span> <Markdown text={choice.text} /></span>
            </label>
          ))}
        </fieldset>
      ))}
      <div className="decision-actions">
        <button type="submit" className="button primary" disabled={!ready}>{CHECK_ANSWERS}</button>
        <button type="button" className="button" onClick={onCancel}>Cancel</button>
        <span className="muted">Every question right passes. You can take it again.</span>
      </div>
    </form>
  );
}

function QuizResults({ graded, live, note, onAgain, onClose }: { graded: Graded; live: boolean; note: { tone: Tone; text: string } | null; onAgain: () => void; onClose: () => void }) {
  return (
    <div className="quiz-results" aria-live={live ? 'polite' : undefined}>
      {graded.perQuestion.map(({ question, given, right }) => {
        const picked = question.choices.find((choice) => choice.key === given);
        const answer = question.choices.find((choice) => choice.key === question.answer);
        return (
          <div key={question.number} className={right ? 'quiz-answer' : 'quiz-answer wrong'}>
            <span className={right ? 'quiz-mark' : 'quiz-mark wrong'} aria-label={right ? 'right' : 'wrong'}>
              <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round">{right ? <path d="M5 12l5 5L20 7" /> : <path d="M6 6l12 12M18 6L6 18" />}</svg>
            </span>
            <div className="quiz-answer-body">
              <div className="strong"><span className="question-number">{question.number}.</span> <Markdown className="question-text" text={question.text} /></div>
              <div><span className="muted">You said: </span>{picked === undefined ? <span className="muted">nothing</span> : <>{picked.key}) {picked.text}</>}</div>
              {!right && <div><span className="muted">Right answer: </span>{answer === undefined ? <span className="muted">not in the answer key</span> : <>{answer.key}) {answer.text}</>}</div>}
              {question.because !== null && <div className="quiz-because"><span className="muted">Because </span>{question.because}</div>}
            </div>
          </div>
        );
      })}
      <div className="decision-actions">
        <span className={graded.passed ? 'strong tone-running' : 'strong tone-needs-you'}>
          {graded.passed ? `Passed: ${graded.right} of ${graded.total} right. The draft PR goes ready for review.` : `${graded.right} of ${graded.total} right. Every question right passes.`}
        </span>
        {!graded.passed && <button type="button" className="button primary" onClick={onAgain}>Take it again</button>}
        <button type="button" className="button" onClick={onClose}>Close</button>
        {note !== null && <span className={`quiz-note tone-${note.tone}`}>{note.text}</span>}
      </div>
    </div>
  );
}
