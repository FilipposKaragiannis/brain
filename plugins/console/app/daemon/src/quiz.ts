import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import type { Quiz, QuizChoice, QuizQuestion, QuizResult } from './snapshot.ts';

/*
 * The quiz the flow's explain step writes, `<reports>/quiz.md`, and the result `quiz.sh answer`
 * keeps beside it, `<reports>/quiz.json`. The same parse as the plugin's `scripts/_quiz.py`:
 * a numbered question, its choices (`a) ...`, one per line or sharing one), a `Because:` line
 * that may run on, and the key in `<!-- answers: 1b 2a -->`. The console shows the quiz on the
 * Gates and Pull requests pages and grades a try locally for the instant result; the action
 * `quiz.answer` runs the plugin's grader, which keeps the result and marks the draft PR ready.
 */

const QUESTION = /^\s*(\d+)[.)]\s+(.*)$/;
const CHOICE = /(?:(?<=\s)|^)([a-h])\)\s*/;
const BECAUSE = /^\s*\**(?:because|why)\**\s*:\**\s*(.*)$/i;
const ANSWERS = /<!--\s*answers:\s*([^>]*?)\s*-->/gi;
const COMMENT = /<!--[\s\S]*?-->/g;
const TITLE = /^\s*#+\s*(.+?)\s*$/;
const KEY = /(\d+)\s*([a-h])/gi;

type Draft = { number: number; lines: string[]; because: string[] };

/** The questions and the key in a quiz.md; a file with no numbered question gives none. */
export function parseQuiz(text: string): { title: string | null; questions: QuizQuestion[] } {
  const key = new Map<number, string>();
  for (const found of text.matchAll(ANSWERS)) {
    for (const [, number, letter] of (found[1] ?? '').matchAll(KEY)) key.set(Number(number), letter!.toLowerCase());
  }
  const body = text.replace(COMMENT, '');
  let title: string | null = null;
  const drafts: Draft[] = [];
  let current: Draft | null = null;
  for (const raw of body.split('\n')) {
    const line = raw.trimEnd();
    if (current === null) {
      const heading = TITLE.exec(line);
      if (heading !== null && title === null) title = heading[1]!;
    }
    const started = QUESTION.exec(line);
    if (started !== null && (current === null || current.lines.some((entry) => CHOICE.test(entry)) === false || Number(started[1]) === current.number + 1)) {
      current = { number: Number(started[1]), lines: [started[2]!], because: [] };
      drafts.push(current);
      continue;
    }
    if (current === null || line.trim() === '') continue;
    const because = BECAUSE.exec(line);
    if (because !== null) { current.because.push(because[1]!.trim()); continue; }
    if (current.because.length > 0) { current.because.push(line.trim()); continue; }
    current.lines.push(line.trim());
  }
  return { title, questions: drafts.map((draft) => question(draft, key)) };
}

function question(draft: Draft, key: Map<number, string>): QuizQuestion {
  const text: string[] = [];
  const choices: QuizChoice[] = [];
  const append = (more: string): void => {
    if (more === '') return;
    if (choices.length > 0) choices[choices.length - 1]!.text = `${choices[choices.length - 1]!.text} ${more}`.trim();
    else text.push(more);
  };
  for (const line of draft.lines) {
    const parts = line.split(new RegExp(CHOICE.source));
    append(parts[0]!.trim());
    for (let index = 1; index < parts.length; index += 2) choices.push({ key: parts[index]!.toLowerCase(), text: (parts[index + 1] ?? '').trim() });
  }
  const because = draft.because.join(' ').trim();
  return { number: draft.number, text: text.join(' '), choices, answer: key.get(draft.number) ?? null, because: because === '' ? null : because };
}

/** The result `quiz.sh answer` wrote, or null when the file is not one. */
export function parseQuizResult(source: string): QuizResult | null {
  try {
    const value = JSON.parse(source) as Record<string, unknown>;
    const given = typeof value['given'] === 'object' && value['given'] !== null ? value['given'] as Record<string, unknown> : {};
    if (typeof value['at'] !== 'string' || typeof value['right'] !== 'number' || typeof value['total'] !== 'number') return null;
    return {
      at: value['at'],
      right: value['right'],
      total: value['total'],
      passed: value['passed'] === true,
      given: Object.fromEntries(Object.entries(given).filter(([, letter]) => typeof letter === 'string') as [string, string][]),
    };
  } catch { return null; }
}

const QUIZ_FILE = 'quiz.md';
const RESULT_FILE = 'quiz.json';

async function readText(file: string): Promise<string | null> {
  try { return await readFile(file, 'utf8'); } catch { return null; }
}

/**
 * Every item with a quiz under `<root>/.flow/reports/<slug>/quiz.md`, by slug, over the roots in
 * order: the first root that holds an item's quiz wins, as `steward.sh reports` looks (the claimed
 * worktree, then the pool, then the main worktree). A quiz with no question is skipped.
 */
export async function readQuizzes(roots: string[]): Promise<Record<string, Quiz>> {
  const found: Record<string, Quiz> = {};
  for (const root of roots) {
    const reports = path.join(root, '.flow', 'reports');
    let slugs: string[];
    try { slugs = await readdir(reports); } catch { continue; }
    for (const slug of slugs.sort()) {
      if (slug in found) continue;
      const file = path.join(reports, slug, QUIZ_FILE);
      const text = await readText(file);
      if (text === null) continue;
      const parsed = parseQuiz(text);
      if (parsed.questions.length === 0) continue;
      const result = await readText(path.join(reports, slug, RESULT_FILE));
      found[slug] = { file, title: parsed.title, questions: parsed.questions, result: result === null ? null : parseQuizResult(result) };
    }
  }
  return found;
}
