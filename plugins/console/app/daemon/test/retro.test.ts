import assert from 'node:assert/strict';
import { test } from 'node:test';
import { lessonsSinceRetro, parseLessons, parseRetrosLog, retroRuns } from '../src/retro.ts';
import type { RetroFacts } from '../src/retro.ts';

const LESSONS = [
  '{"time":"2026-10-12T09:14:00Z","kind":"review-blocker","item":"gh#7","step":"implement","rule":"T-09","text":"Two behaviours in one test.","host":"claude"}',
  '{"time":"2026-10-14T10:02:00Z","kind":"escalation" cut short',
  '',
  '{"time":"2026-10-20T11:47:00Z","kind":"","item":"gh#9","step":"","rule":"","text":"No rule fits.","host":"codex"}',
  '',
].join('\n');

const report = (date: string) => ({ file: `/p/.flow/reports/retro-${date}.md`, date, text: `# Retro ${date}` });

/** Retro facts with lessons on the given counted lines, `lessonLines` lines in all, and runs that read so far the given counts, newest first. */
function facts(lines: number[], lessonLines: number, readSoFar: number[]): RetroFacts {
  return {
    lessons: lines.map((line) => ({ line, at: null, kind: 'other', item: null, step: null, rule: null, text: `lesson ${line}`, host: null })),
    lessonLines,
    retros: readSoFar.map((count) => ({ date: '2026-10-19', at: '2026-10-19T07:00:00Z', lessonsRead: count, lessonsReadSoFar: count, findings: '', applied: '', report: null })),
  };
}

test('ParseLessons_MalformedLine_SkippedButCounted', () => {
  assert.deepEqual(parseLessons(LESSONS).map((lesson) => lesson.line), [1, 3], 'because retro.sh counts every non-empty line, so a broken one still moves the lessons after it');
});

test('ParseLessons_WrittenLine_EveryKeyRead', () => {
  assert.deepEqual(parseLessons(LESSONS)[0], { line: 1, at: '2026-10-12T09:14:00Z', kind: 'review-blocker', item: 'gh#7', step: 'implement', rule: 'T-09', text: 'Two behaviours in one test.', host: 'claude' }, 'because the page shows what lesson.sh wrote');
});

test('ParseLessons_EmptyStepAndRule_AreNull', () => {
  const lesson = parseLessons(LESSONS)[1];
  assert.deepEqual([lesson?.step, lesson?.rule], [null, null], 'because lesson.sh writes an empty string for an option it was not given');
});

test('ParseLessons_EmptyKind_IsOther', () => {
  assert.equal(parseLessons(LESSONS)[1]?.kind, 'other', 'because other is the kind lesson.sh names for a lesson that fits none');
});

test('ParseLessons_JsonThatIsNotAnObject_Skipped', () => {
  assert.deepEqual(parseLessons('["a list"]\n"a string"\n'), [], 'because only an object is a lesson');
});

test('ParseRetrosLog_LineWithoutACount_Skipped', () => {
  const lines = parseRetrosLog('2026-10-15T07:00:12Z\t2\t1\t0\nwritten by hand\n2026-10-19T07:00:31Z\tmany\n');
  assert.deepEqual(lines.map((line) => line.at), ['2026-10-15T07:00:12Z'], 'because a line is a retro only with its time and a whole count of lessons read');
});

test('ParseRetrosLog_FindingsAndApplied_KeptAsWritten', () => {
  const [line] = parseRetrosLog('2026-10-19T07:00:31Z\t3\t2 findings\t1 PR\n');
  assert.deepEqual([line?.findings, line?.applied], ['2 findings', '1 PR'], 'because the skill does not fix the shape of the last two columns');
});

test('RetroRuns_LessonsRead_IsTheCountLessTheRunBefore', () => {
  const runs = retroRuns(parseRetrosLog('2026-10-15T07:00:00Z\t2\n2026-10-19T07:00:00Z\t5\n'), []);
  assert.deepEqual(runs.map((run) => run.lessonsRead), [3, 2], 'because the second column counts the lessons read to date, so each run read the difference');
});

test('RetroRuns_CountBelowTheRunBefore_ReadsItsWholeCount', () => {
  const runs = retroRuns(parseRetrosLog('2026-10-15T07:00:00Z\t9\n2026-10-19T07:00:00Z\t4\n'), []);
  assert.equal(runs[0]?.lessonsRead, 4, 'because a smaller count means the lessons file was reset, and retro.sh then reads every line');
});

test('RetroRuns_ReportOfTheDay_GoesToTheLastRunThatDay', () => {
  const runs = retroRuns(parseRetrosLog('2026-10-19T07:00:00Z\t2\n2026-10-19T19:00:00Z\t3\n'), [report('2026-10-19')]);
  assert.deepEqual(runs.map((run) => run.report?.text ?? null), ['# Retro 2026-10-19', null], 'because a later run that day rewrote the report, so it is that run\'s');
});

test('RetroRuns_ReportNoLineNames_IsARunOfItsOwn', () => {
  const runs = retroRuns(parseRetrosLog('2026-10-19T07:00:00Z\t3\n'), [report('2026-10-08')]);
  assert.deepEqual(runs.map((run) => [run.date, run.at]), [['2026-10-19', '2026-10-19T07:00:00Z'], ['2026-10-08', null]], 'because a report whose run wrote no log line is still a retro the owner wants to read');
});

test('RetroRuns_RunPastMidnightLocally_TakesTheReportOfItsLocalDay', () => {
  const zone = process.env.TZ;
  process.env.TZ = 'Europe/Athens';
  try {
    const runs = retroRuns(parseRetrosLog('2026-10-18T22:00:00Z\t3\n'), [report('2026-10-19')]);
    assert.deepEqual(runs.map((run) => [run.date, run.report?.text ?? null]), [['2026-10-19', '# Retro 2026-10-19']], 'because retro.sh names the report by the local date +%F, which in Athens is already the 19th');
  } finally {
    if (zone === undefined) delete process.env.TZ; else process.env.TZ = zone;
  }
});

test('RetroRuns_NewestFirst', () => {
  const runs = retroRuns(parseRetrosLog('2026-10-05T07:00:00Z\t1\n2026-10-19T07:00:00Z\t3\n'), [report('2026-10-12')]);
  assert.deepEqual(runs.map((run) => run.date), ['2026-10-19', '2026-10-12', '2026-10-05'], 'because the page shows the latest retro first');
});

test('LessonsSinceRetro_LessonsPastTheLastRunsCount', () => {
  assert.equal(lessonsSinceRetro(facts([1, 2, 4, 5], 6, [3, 2])), 2, 'because the newest run read three lines, so the lessons on lines four and five are new');
});

test('LessonsSinceRetro_NoRetro_EveryLesson', () => {
  assert.equal(lessonsSinceRetro(facts([1, 2, 4], 4, [])), 3, 'because the first retro reads the whole log');
});

test('LessonsSinceRetro_CountPastTheFilesLines_EveryLesson', () => {
  assert.equal(lessonsSinceRetro(facts([1, 2], 2, [7])), 2, 'because a count past the file means it was reset, and retro.sh then reads every line');
});
