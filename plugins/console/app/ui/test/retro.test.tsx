import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import type { ActionRecord, Job, Lesson, RetroRun, Snapshot } from '../../daemon/src/snapshot.ts';
import { lessonGroups } from '../src/retro.ts';
import { Retro } from '../src/screens/Retro.tsx';
import { actionRecord, boardItem, FakeDaemon, HTTP_ACCEPTED, snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

afterEach(cleanup);

const ACTIONS_PATH = '/api/projects/project/actions';

function lesson(line: number, kind: string, rule: string | null, item: string | null, text: string): Lesson {
  return { line, at: '2026-10-20T11:47:00Z', kind, item, step: 'implement', rule, text, host: 'claude' };
}

const LESSONS: Lesson[] = [
  lesson(1, 'escalation', null, 'gh#9', 'The spec named no tracker.'),
  lesson(2, 'review-blocker', 'T-09', 'gh#7', 'Two behaviours in one test.'),
  lesson(4, 'review-blocker', 'T-09', 'gh#9', 'A test asserted three things.'),
  lesson(5, 'correction', 'N-05', 'gh#7', 'degPerSec is an abbreviation.'),
];

const RUN: RetroRun = { date: '2026-10-19', at: '2026-10-19T07:00:31Z', lessonsRead: 1, lessonsReadSoFar: 3, findings: '1', applied: '1', report: { file: '/p/.flow/reports/retro-2026-10-19.md', text: '# Retro 2026-10-19\n\n## Findings\n- T-09 broken twice' } };
const OLDER: RetroRun = { date: '2026-10-15', at: '2026-10-15T07:00:12Z', lessonsRead: 2, lessonsReadSoFar: 2, findings: '', applied: '', report: null };
const RETRO_JOB: Job = { name: 'retro', job: 'retro', host: 'codex', configured: true, state: 'scheduled', schedule: 'weekly sun 07:00', args: 'codex', installed: true, loaded: true, paused: false, running: [], last: null, recent: [], workers: [], next: 'sun 07:00', runsThisWeek: 0, failedThisWeek: 0 };

/** A snapshot with the lessons and runs given, two of the lessons after the last retro unless said. */
function withRetro(extra: Partial<Snapshot>, lessonsSinceRetro = 2): Snapshot {
  const base = snapshotAt(TAKEN_AT, 0);
  return { ...base, lessons: LESSONS, retros: [RUN, OLDER], items: [boardItem('gh#7', 'Rod dynamics')], ...extra, counts: { ...base.counts, lessonsSinceRetro } };
}

async function renderRetro(snapshot: Snapshot): Promise<unknown[]> {
  const daemon = new FakeDaemon();
  const posted: unknown[] = [];
  daemon.answer('POST', ACTIONS_PATH, (body) => {
    posted.push(body);
    const { kind, args } = body as { kind: ActionRecord['kind']; args: Record<string, string> };
    return { status: HTTP_ACCEPTED, body: { action: { ...actionRecord('p1', 'running', {}), kind, args } } };
  });
  const Wrapper = daemon.screenWrapper();
  render(<Wrapper><Retro snapshot={snapshot} /></Wrapper>);
  await act(async () => {});
  return posted;
}

test('RetroPage_HeadLine_CountsTheLessonsInAllAndSinceTheLastRetro', async () => {
  await renderRetro(withRetro({}));
  expect(screen.getByLabelText('Summary').textContent, 'because the owner sees at a glance how much the next retro will read').toMatch(/4 lessons in all · 2 since the last retro/);
});

test('RetroPage_HeadLine_SaysWhenTheLastRetroRan', async () => {
  await renderRetro(withRetro({}));
  expect(screen.getByLabelText('Summary').textContent, 'because the newest run is the one the count is measured from').toMatch(/Last retro 2026-10-19/);
});

test('RetroPage_NoRetroYet_HeadLineSaysSo', async () => {
  await renderRetro(withRetro({ retros: [] }, 4));
  expect(screen.getByLabelText('Summary').textContent, 'because before the first retro there is no date to show').toMatch(/No retro has run yet/);
});

test('RetroPage_Lessons_GroupedByKindTheMostLessonsFirst', async () => {
  await renderRetro(withRetro({}, 4));
  const kinds = screen.getAllByRole('region', { name: /^Kind / }).map((region) => region.getAttribute('aria-label'));
  expect(kinds, 'because a kind that keeps coming back is the theme the owner should see first').toEqual(['Kind review-blocker', 'Kind correction', 'Kind escalation']);
});

test('RetroPage_LessonsOfAKind_GroupedByRule', async () => {
  await renderRetro(withRetro({}, 4));
  const blockers = screen.getByRole('region', { name: 'Kind review-blocker' });
  expect(within(within(blockers).getByLabelText('Rule T-09')).getAllByRole('listitem'), 'because two blockers on one rule are one theme').toHaveLength(2);
});

test('RetroPage_Lesson_LinksItsItem', async () => {
  await renderRetro(withRetro({}, 1));
  const row = screen.getByText('degPerSec is an abbreviation.').closest('li')!;
  expect(within(row).getByRole('link', { name: 'gh#7' }).getAttribute('href'), 'because the lesson came from that item, whose page explains it').toBe('https://github.com/owner/project/issues/7');
});

test('RetroPage_Lesson_NamesItsStep', async () => {
  await renderRetro(withRetro({}, 1));
  expect(screen.getByText('degPerSec is an abbreviation.').closest('li')!.textContent, 'because the step tells which agent learnt it').toMatch(/implement/);
});

test('RetroPage_FirstView_OnlyTheLessonsSinceTheLastRetro', async () => {
  await renderRetro(withRetro({}));
  expect(screen.queryByText('Two behaviours in one test.'), 'because a lesson the last retro already read is not news').toBeNull();
});

test('RetroPage_AllTab_EveryLesson', async () => {
  await renderRetro(withRetro({}));
  await act(async () => { fireEvent.click(screen.getByRole('tab', { name: 'All (4)' })); });
  expect(screen.queryByText('Two behaviours in one test.'), 'because All shows the lessons earlier retros read too').not.toBeNull();
});

test('RetroPage_RetroRun_ShowsItsDateAndTheLessonsItRead', async () => {
  await renderRetro(withRetro({}));
  expect(within(screen.getByRole('listitem', { name: 'Retro 2026-10-15' })).getByText(/read 2 lessons/), 'because each run says how much of the log it covered').not.toBeNull();
});

test('RetroPage_RetroReport_RenderedAsMarkdown', async () => {
  await renderRetro(withRetro({}));
  const run = screen.getByRole('listitem', { name: 'Retro 2026-10-19' });
  expect(within(run).getByRole('heading', { name: 'Findings' }), 'because the report is markdown the retro wrote, read as a document').not.toBeNull();
});

test('RetroPage_RunRetroNow_StartsTheRetroJobOnItsSchedulesHost', async () => {
  const posted = await renderRetro(withRetro({ jobs: [RETRO_JOB] }));
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Run retro now' })); });
  expect(posted, 'because the button runs the retro job once through job.start, on the host its schedule uses').toEqual([{ kind: 'job.start', args: { job: 'retro', host: 'codex' } }]);
});

test('LessonGroups_LessonsWithNoRule_LastInTheirKind', () => {
  const groups = lessonGroups([lesson(1, 'escalation', null, null, 'a'), lesson(2, 'escalation', null, null, 'b'), lesson(3, 'escalation', 'D-02', null, 'c')]);
  expect(groups[0]?.rules.map((rule) => rule.rule), 'because a rule id is a theme, and the lessons that name none are the rest').toEqual(['D-02', null]);
});
