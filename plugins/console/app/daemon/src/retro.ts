import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import type { Lesson, RetroRun } from './snapshot.ts';

/*
 * What the flow learns and what its retro made of it, all under the flow home and never in git.
 * `lessons.jsonl` holds one JSON object per line (`lesson.sh`: time, kind, item, step, rule, text,
 * host). `retros.log` holds one line per retro, `<time>\t<lessons read so far>\t<findings>\t<applied>`,
 * where the second column counts the lessons.jsonl lines read to date, as `grep -c .` counts them,
 * malformed lines included. `reports/retro-<date>.md` is the report of the retro that ran that day.
 */

const LESSONS_FILE = 'lessons.jsonl';
const RETROS_FILE = 'retros.log';
const REPORT_FILE = /^retro-(\d{4}-\d{2}-\d{2})\.md$/;
const READ_SO_FAR = /^\d+$/;
/** The length of the `YYYY-MM-DD` day that opens an ISO time. */
const DAY_LENGTH = 10;

/** The lessons, the line count the retro counts against, and every retro run, newest first. */
export type RetroFacts = { lessons: Lesson[]; lessonLines: number; retros: RetroRun[] };

/** A retros.log line that reads: its time and the lessons read to date, with the two columns after them. */
type LogLine = { at: string; readSoFar: number; findings: string; applied: string };

/** A report file under the flow home's reports: its day and its text. */
type Report = { file: string; date: string; text: string };

async function readText(file: string): Promise<string | null> {
  try { return await readFile(file, 'utf8'); } catch { return null; }
}

/** The lines that hold at least one character, as `grep -c .` counts them. */
function countedLines(source: string): string[] {
  return source.split('\n').filter((line) => line !== '');
}

function field(value: Record<string, unknown>, key: string): string | null {
  const found = value[key];
  return typeof found === 'string' && found.trim() !== '' ? found : null;
}

/**
 * The lessons in a lessons.jsonl, oldest first. `line` is the lesson's place among the counted
 * lines, so it compares with a retro's lessons read so far. A line that is not a JSON object is
 * skipped but still counted. An empty field is null; an empty kind is `other`, as lesson.sh names it.
 */
export function parseLessons(source: string): Lesson[] {
  const lessons: Lesson[] = [];
  countedLines(source).forEach((raw, index) => {
    let parsed: unknown;
    try { parsed = JSON.parse(raw); } catch { return; }
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return;
    const value = parsed as Record<string, unknown>;
    lessons.push({
      line: index + 1,
      at: field(value, 'time'),
      kind: field(value, 'kind') ?? 'other',
      item: field(value, 'item'),
      step: field(value, 'step'),
      rule: field(value, 'rule'),
      text: field(value, 'text') ?? '',
      host: field(value, 'host'),
    });
  });
  return lessons;
}

/** The retros.log lines that read, oldest first: a time and a whole number of lessons read; any other line is skipped. */
export function parseRetrosLog(source: string): LogLine[] {
  return countedLines(source).flatMap((raw) => {
    const [at = '', readSoFar = '', findings = '', applied = ''] = raw.trimEnd().split('\t');
    if (at.trim() === '' || !READ_SO_FAR.test(readSoFar.trim())) return [];
    return [{ at: at.trim(), readSoFar: Number(readSoFar.trim()), findings: findings.trim(), applied: applied.trim() }];
  });
}

/**
 * Every retro, newest first: each log line with the lessons it read (its count less the line
 * before's, or its whole count when the log was reset, as retro.sh counts) and the report of its
 * day, which the last run of that day wrote; then each report no line names, as a run of its own.
 */
export function retroRuns(lines: LogLine[], reports: Report[]): RetroRun[] {
  const lastOfDay = new Map<string, number>();
  lines.forEach((line, index) => lastOfDay.set(line.at.slice(0, DAY_LENGTH), index));
  const logged: RetroRun[] = lines.map((line, index) => {
    const date = line.at.slice(0, DAY_LENGTH);
    const before = index === 0 ? 0 : lines[index - 1]!.readSoFar;
    const lessonsRead = line.readSoFar >= before ? line.readSoFar - before : line.readSoFar;
    const report = lastOfDay.get(date) === index ? reports.find((each) => each.date === date) ?? null : null;
    return { date, at: line.at, lessonsRead, lessonsReadSoFar: line.readSoFar, findings: line.findings, applied: line.applied, report: report === null ? null : { file: report.file, text: report.text } };
  });
  const named = new Set(lastOfDay.keys());
  const unlogged: RetroRun[] = reports.filter((report) => !named.has(report.date)).map((report) => ({
    date: report.date, at: null, lessonsRead: null, lessonsReadSoFar: null, findings: '', applied: '', report: { file: report.file, text: report.text },
  }));
  return [...logged.reverse(), ...unlogged].sort((left, right) => right.date.localeCompare(left.date));
}

/**
 * How many lessons came after the last retro: those on a line past its lessons read so far. With
 * no retro, or a count past the file's lines (the file was reset), every lesson is new, as retro.sh says.
 */
export function lessonsSinceRetro(facts: RetroFacts): number {
  const readSoFar = facts.retros.find((run) => run.lessonsReadSoFar !== null)?.lessonsReadSoFar ?? 0;
  if (readSoFar > facts.lessonLines) return facts.lessons.length;
  return facts.lessons.filter((lesson) => lesson.line > readSoFar).length;
}

async function readReports(flowHome: string): Promise<Report[]> {
  const directory = path.join(flowHome, 'reports');
  let names: string[];
  try { names = await readdir(directory); } catch { return []; }
  const reports: Report[] = [];
  for (const name of names.sort()) {
    const date = REPORT_FILE.exec(name)?.[1];
    if (date === undefined) continue;
    const file = path.join(directory, name);
    const text = await readText(file);
    if (text !== null) reports.push({ file, date, text });
  }
  return reports;
}

/** The lessons and the retros under a flow home; a missing file is empty, never an error. */
export async function readRetroFacts(flowHome: string): Promise<RetroFacts> {
  const lessonsSource = (await readText(path.join(flowHome, LESSONS_FILE))) ?? '';
  const lines = parseRetrosLog((await readText(path.join(flowHome, RETROS_FILE))) ?? '');
  return { lessons: parseLessons(lessonsSource), lessonLines: countedLines(lessonsSource).length, retros: retroRuns(lines, await readReports(flowHome)) };
}
