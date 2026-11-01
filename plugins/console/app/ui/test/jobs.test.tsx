import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest';
import type { ActionRecord, Job, JobRun, Snapshot } from '../../daemon/src/snapshot.ts';
import { TICK_MS } from '../src/clock.tsx';
import { Jobs, OVERDUE_HELP } from '../src/screens/Jobs.tsx';
import { OUTCOME_SHOWN_MS } from '../src/ui.tsx';
import { FakeDaemon, HTTP_ACCEPTED, actionRecord, flowEvent, snapshotAt, TAKEN_AT } from './fakeDaemon.tsx';

afterEach(cleanup);

const ACTIONS_PATH = '/api/projects/project/actions';

const JOB: Job = { name: 'next', job: 'next', host: 'claude', configured: true, state: 'scheduled', schedule: 'every 30m', args: '', installed: true, loaded: true, paused: false, running: [], last: null, recent: [], workers: [], next: '18:30', runsThisWeek: 0, failedThisWeek: 0 };

async function renderSnapshot(extra: Partial<Snapshot>, daemon = new FakeDaemon(), clock?: () => number): Promise<unknown[]> {
  const posted: unknown[] = [];
  daemon.answer('POST', ACTIONS_PATH, (body) => {
    posted.push(body);
    const { kind, args } = body as { kind: ActionRecord['kind']; args: Record<string, string> };
    return { status: HTTP_ACCEPTED, body: { action: { ...actionRecord('p1', 'done', {}), kind, args, outcome: 'finished' } } };
  });
  const Wrapper = daemon.screenWrapper(clock);
  render(<Wrapper><Jobs snapshot={{ ...snapshotAt(TAKEN_AT, 0), ...extra }} /></Wrapper>);
  await act(async () => {});
  return posted;
}

function jobRun(at: string, outcome: string, result: string, reason: string | null): JobRun {
  return { at, seconds: 0, exit: 0, result, outcome, reason, worker: 'next-1', host: 'claude' };
}

test('JobsScreen_AnySnapshot_SchedulesIsAPlainModule', async () => {
  await renderSnapshot({ jobs: [JOB] });
  const schedules = screen.getByRole('heading', { name: 'Schedules' });
  expect(schedules.closest('details'), 'because the jobs list is the page itself, so it does not fold').toBeNull();
  expect(within(schedules.closest('section')!).getByRole('listitem', { name: 'Job next' }), 'because each schedule is a row of the list').not.toBeNull();
});

test('JobsScreen_AnySnapshot_SideHoldsTheRunOncePanelAndEvents', async () => {
  await renderSnapshot({ jobs: [JOB], events: [flowEvent('gh#9', 'claim', 'next claimed gh#9')] });
  const side = document.querySelector('.jobs-side')!;
  expect(within(side as HTMLElement).getByRole('tab', { name: 'Run once' }), 'because the schedule and run once panel sits beside the jobs').not.toBeNull();
  expect(within(side as HTMLElement).getByRole('heading', { name: 'Events' }), 'because the latest events sit beside the jobs').not.toBeNull();
  expect(document.querySelector('details.module'), 'because nothing on the Jobs page folds as a whole').toBeNull();
});

test('JobsScreen_WithRuns_ShowsNoRunCards', async () => {
  await renderSnapshot({ jobs: [JOB], runs: [{ item: 'gh#9', step: 'implement', profile: 'default', worktree: 'wt-3', host: 'claude', startedAt: TAKEN_AT, alive: false }] });
  expect(screen.queryByRole('heading', { name: 'Runs' }), 'because the runs live on the Agents page').toBeNull();
});

test('JobRow_OpenInTerminal_OpensTheRootFollowingTheJobsLog', async () => {
  const posted = await renderSnapshot({ jobs: [JOB] });
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Open in Terminal' })); });
  expect(posted, 'because a job has no folder of its own: it opens the project root and follows its log').toEqual([{ kind: 'terminal.open', args: { path: '/p', job: 'next' } }]);
});

test('StoppedHost_ShowsWhyAndClears', async () => {
  const posted = await renderSnapshot({ stoppedHosts: [{ host: 'codex', cause: 'spend-limit', said: 'You have hit your limit.', at: TAKEN_AT, item: 'gh#9' }] });
  const card = screen.getByRole('region', { name: 'codex is stopped' });
  expect(card.textContent, 'because the owner needs the cause and what the host said').toMatch(/Stopped on a spend limit.*You have hit your limit\./);
  await act(async () => { fireEvent.click(within(card).getByRole('button', { name: 'Clear codex' })); });
  expect(posted, 'because clearing names the host').toEqual([{ kind: 'host.clear', args: { host: 'codex' } }]);
});

test('OverdueJob_SaysWhatOverdueMeans', async () => {
  await renderSnapshot({ jobs: [{ ...JOB, state: 'overdue', next: 'due' }] });
  const job = screen.getByRole('listitem', { name: 'Job next' });
  expect(within(job).getByText('overdue').getAttribute('title'), 'because "overdue" alone does not say whether anything is wrong').toBe(OVERDUE_HELP);
});

test('ScheduledJob_SaysWhenItRunsNext', async () => {
  await renderSnapshot({ jobs: [JOB] });
  expect(screen.getByRole('listitem', { name: 'Job next' }).textContent, 'because a schedule\'s row leads with when it runs').toMatch(/next 18:30/);
});

test('JobHistory_SaysWhyARunSkipped', async () => {
  const skipped = jobRun('2026-10-24T18:00:00Z', 'skipped', 'skipped: run 36596 still going', 'run 36596 still going');
  await renderSnapshot({ jobs: [{ ...JOB, last: skipped, recent: [skipped, jobRun('2026-10-24T17:30:00Z', 'idle', 'nothing ready', null)] }] });
  const runs = screen.getByRole('list', { name: 'Runs of next' });
  expect(within(runs).getAllByRole('listitem').map((row) => row.textContent), 'because each run says what it did, a skip with its reason').toEqual([
    expect.stringMatching(/skipped.*run 36596 still going/),
    expect.stringMatching(/idle.*nothing ready/),
  ]);
});

test('RunOnce_SendsOnlyWhatIsSet', async () => {
  const posted = await renderSnapshot({ jobs: [JOB] });
  await act(async () => { fireEvent.click(screen.getByRole('tab', { name: 'Run once' })); });
  const form = screen.getByRole('form', { name: 'Run next once' });
  fireEvent.change(within(form).getByLabelText('Host'), { target: { value: 'codex' } });
  fireEvent.change(within(form).getByLabelText('Item'), { target: { value: 'gh#12' } });
  fireEvent.change(within(form).getByLabelText('Max steps'), { target: { value: '15' } });
  fireEvent.change(within(form).getByLabelText('Effort'), { target: { value: 'high' } });
  await act(async () => { fireEvent.click(within(form).getByRole('button', { name: 'Start' })); });
  expect(posted, 'because empty fields fall back to the config, so they are not sent').toEqual([{ kind: 'job.start', args: { job: 'next', host: 'codex', item: 'gh#12', maxSteps: '15', effort: 'high' } }]);
  expect(screen.getByRole('status').textContent, 'because the panel stays and says the run started').toMatch(/Started next on codex/);
});

test('RunOnce_BadWorkers_SaysSoAndSendsNothing', async () => {
  const posted = await renderSnapshot({ jobs: [JOB] });
  await act(async () => { fireEvent.click(screen.getByRole('tab', { name: 'Run once' })); });
  fireEvent.change(screen.getByLabelText('Workers'), { target: { value: 'two' } });
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Start' })); });
  expect(screen.getByRole('alert').textContent, 'because the owner must know why nothing started').toBe('Workers is a whole number from 1 to 99.');
  expect(posted, 'because a bad form never reaches the daemon').toEqual([]);
});

test('Panel_StaysOpenOnScheduleWithNoJobs', async () => {
  await renderSnapshot({ jobs: [] });
  expect(screen.getByRole('tab', { name: 'Schedule' }).getAttribute('aria-selected'), 'because the panel is always there and opens on Schedule').toBe('true');
  expect(screen.getByRole('form', { name: 'Schedule next' }), 'because a first schedule is added from it').not.toBeNull();
});

test('EditNext_OpensADialogWithItsSettingsAndSavesInPlace', async () => {
  const posted = await renderSnapshot({ jobs: [JOB, { ...JOB, name: 'next-codex', host: 'codex', args: '--max-steps 15' }] });
  await act(async () => { fireEvent.click(within(screen.getByRole('listitem', { name: 'Job next-codex' })).getByRole('button', { name: 'Edit…' })); });
  const dialog = screen.getByRole('dialog', { name: 'Edit next-codex' });
  expect(dialog.getAttribute('aria-modal'), 'because editing covers the page, apart from the side panel').toBe('true');
  expect((within(dialog).getByLabelText('Host') as HTMLSelectElement).value, 'because the dialog loads what the schedule runs').toBe('codex');
  fireEvent.change(within(dialog).getByLabelText('Every'), { target: { value: '2' } });
  fireEvent.change(within(dialog).getByLabelText('Unit'), { target: { value: 'h' } });
  await act(async () => { fireEvent.click(within(dialog).getByRole('button', { name: 'Save next-codex' })); });
  expect(posted, 'because saving rewrites that schedule under its own name').toEqual([{ kind: 'job.schedule', args: { job: 'next-codex', schedule: 'every 2h codex --max-steps 15' } }]);
  expect(screen.queryByRole('dialog'), 'because a saved edit closes the dialog').toBeNull();
});

test('EditOtherJob_SetsHostModelAndEffortAndKeepsItsOwnOptions', async () => {
  const posted = await renderSnapshot({ jobs: [{ ...JOB, name: 'intake', job: 'intake', schedule: 'every 15m', args: '--batch 5 --effort low' }] });
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Edit…' })); });
  const dialog = screen.getByRole('dialog', { name: 'Edit intake' });
  expect(within(dialog).queryByLabelText('Item'), 'because only next takes an item and limits').toBeNull();
  expect((within(dialog).getByLabelText('Effort') as HTMLSelectElement).value, 'because the dialog loads the schedule\'s own effort').toBe('low');
  fireEvent.change(within(dialog).getByLabelText('Runs'), { target: { value: 'daily' } });
  fireEvent.change(within(dialog).getByLabelText('At'), { target: { value: '03:30' } });
  fireEvent.change(within(dialog).getByLabelText('Host'), { target: { value: 'codex' } });
  fireEvent.change(within(dialog).getByLabelText('Model'), { target: { value: 'gpt-6-luna' } });
  await act(async () => { fireEvent.click(within(dialog).getByRole('button', { name: 'Save intake' })); });
  expect(posted, 'because the job keeps its own options and runs on the pair picked').toEqual([{ kind: 'job.schedule', args: { job: 'intake', schedule: 'daily 03:30 codex --batch 5 --model gpt-6-luna --effort low' } }]);
});

test('EditDialog_EscapeClosesWithoutSaving', async () => {
  const posted = await renderSnapshot({ jobs: [JOB] });
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Edit…' })); });
  await act(async () => { fireEvent.keyDown(window, { key: 'Escape' }); });
  expect(screen.queryByRole('dialog'), 'because Escape leaves the dialog').toBeNull();
  expect(posted, 'because nothing was saved').toEqual([]);
});

test('JobRow_ShowsItsButtonsOutsideTheHistory', async () => {
  await renderSnapshot({ jobs: [JOB] });
  const row = screen.getByRole('listitem', { name: 'Job next' });
  for (const name of ['Run now', 'Edit…', 'Pause', 'Unschedule']) {
    expect(within(row).getByRole('button', { name }).closest('.job-more'), `because ${name} is one click away in the row`).toBeNull();
  }
});

test('JobHistory_ScrollsInABoxOfItsOwn', async () => {
  await renderSnapshot({ jobs: [{ ...JOB, recent: [jobRun(TAKEN_AT, 'idle', 'quiet', null)] }] });
  expect(screen.getByRole('list', { name: 'Runs of next' }).closest('.job-history-box'), 'because a long history scrolls, so the row stays its size').not.toBeNull();
});

test('Schedule_AddsANamedScheduleBesideNext', async () => {
  const posted = await renderSnapshot({ jobs: [JOB] });
  const form = screen.getByRole('form', { name: 'Schedule next' });
  fireEvent.change(within(form).getByLabelText('Name'), { target: { value: 'codex' } });
  fireEvent.change(within(form).getByLabelText('Host'), { target: { value: 'codex' } });
  fireEvent.change(within(form).getByLabelText('Max steps'), { target: { value: '15' } });
  await act(async () => { fireEvent.click(within(form).getByRole('button', { name: 'Add next-codex' })); });
  expect(posted, 'because the schedule runs what Run once would').toEqual([{ kind: 'job.schedule', args: { job: 'next-codex', schedule: 'every 30m codex --max-steps 15' } }]);
  expect(screen.getByRole('status').textContent, 'because the panel says what it added').toMatch(/Added next-codex/);
});

test('Schedule_EmptyNameWhileNextExists_PointsToEdit', async () => {
  const posted = await renderSnapshot({ jobs: [JOB] });
  const form = screen.getByRole('form', { name: 'Schedule next' });
  await act(async () => { fireEvent.click(within(form).getByRole('button', { name: 'Add next' })); });
  expect(screen.getByRole('alert').textContent, 'because the panel only adds, and next is changed from its row').toMatch(/next already has one.*Edit…/);
  expect(posted, 'because a refused name never reaches the daemon').toEqual([]);
});

test('Schedule_TakenName_PointsToEdit', async () => {
  await renderSnapshot({ jobs: [JOB, { ...JOB, name: 'next-codex' }] });
  const form = screen.getByRole('form', { name: 'Schedule next' });
  fireEvent.change(within(form).getByLabelText('Name'), { target: { value: 'codex' } });
  await act(async () => { fireEvent.click(within(form).getByRole('button', { name: 'Add next-codex' })); });
  expect(screen.getByRole('alert').textContent, 'because an existing schedule is changed in place').toMatch(/next-codex already exists/);
});

test('Schedule_EmptyNameWithoutNext_AddsNext', async () => {
  const posted = await renderSnapshot({ jobs: [] });
  await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Add next' })); });
  expect(posted, 'because next itself is free while it has no schedule').toEqual([{ kind: 'job.schedule', args: { job: 'next', schedule: 'every 30m claude' } }]);
});

test('Panel_RunsAnotherJobOnceWithItsPair', async () => {
  const posted = await renderSnapshot({ jobs: [JOB] });
  await act(async () => { fireEvent.click(screen.getByRole('tab', { name: 'Run once' })); });
  fireEvent.change(screen.getByLabelText('Job'), { target: { value: 'intake' } });
  const form = screen.getByRole('form', { name: 'Run intake once' });
  expect(within(form).queryByLabelText('Item'), 'because only next takes an item and limits').toBeNull();
  fireEvent.change(within(form).getByLabelText('Effort'), { target: { value: 'low' } });
  await act(async () => { fireEvent.click(within(form).getByRole('button', { name: 'Start' })); });
  expect(posted, 'because every job runs on the host, model and effort picked').toEqual([{ kind: 'job.start', args: { job: 'intake', host: 'claude', effort: 'low' } }]);
  expect(screen.getByRole('status').textContent, 'because intake claims no item, so it shows in its history').toMatch(/in intake's history/);
});

test('Panel_SchedulesAnotherJobUnderItsOwnName', async () => {
  const posted = await renderSnapshot({ jobs: [JOB, { ...JOB, name: 'health', job: 'health', schedule: 'every 15m' }] });
  fireEvent.change(screen.getByLabelText('Job'), { target: { value: 'health' } });
  const form = screen.getByRole('form', { name: 'Schedule health' });
  fireEvent.change(within(form).getByLabelText('Name'), { target: { value: 'codex' } });
  fireEvent.change(within(form).getByLabelText('Host'), { target: { value: 'codex' } });
  await act(async () => { fireEvent.click(within(form).getByRole('button', { name: 'Add health-codex' })); });
  expect(posted, 'because the new schedule starts from health\'s own timing').toEqual([{ kind: 'job.schedule', args: { job: 'health-codex', schedule: 'every 15m codex' } }]);
});

test('Schedule_BadName_SaysSo', async () => {
  const posted = await renderSnapshot({ jobs: [JOB] });
  const form = screen.getByRole('form', { name: 'Schedule next' });
  fireEvent.change(within(form).getByLabelText('Name'), { target: { value: '2nd' } });
  await act(async () => { fireEvent.click(within(form).getByRole('button', { name: 'Add next-2nd' })); });
  expect(screen.getByRole('alert').textContent, 'because a name starting with a digit reads as a worker').toMatch(/starting with a letter/);
  expect(posted, 'because a bad form never reaches the daemon').toEqual([]);
});

test('ModelOther_LetsTheOwnerTypeAName', async () => {
  await renderSnapshot({ jobs: [JOB] });
  const form = screen.getByRole('form', { name: 'Schedule next' });
  expect(within(form).getAllByRole('option').map((option) => option.textContent), 'because the model and effort offer the host\'s own names and the config').toEqual(expect.arrayContaining(['From config', 'opus', 'Other…', 'max']));
  fireEvent.change(within(form).getByLabelText('Model'), { target: { value: 'other' } });
  expect(within(form).getByLabelText('Model name'), 'because a model flow does not list can still be typed').not.toBeNull();
});

test('SwitchingToCodex_DropsAnEffortItDoesNotTake', async () => {
  await renderSnapshot({ jobs: [JOB] });
  fireEvent.change(screen.getByLabelText('Effort'), { target: { value: 'max' } });
  fireEvent.change(screen.getByLabelText('Host'), { target: { value: 'codex' } });
  expect((screen.getByLabelText('Effort') as HTMLSelectElement).value, 'because codex takes up to xhigh, so max falls back to the config').toBe('');
});

test('EverySchedule_HasUnschedule', async () => {
  const posted = await renderSnapshot({ jobs: [JOB, { ...JOB, name: 'next-codex', host: 'codex' }] });
  const row = screen.getByRole('listitem', { name: 'Job next-codex' });
  await act(async () => { fireEvent.click(within(row).getByRole('button', { name: 'Unschedule' })); });
  expect(posted, 'because each schedule can be stopped on its own').toEqual([{ kind: 'job.unschedule', args: { job: 'next-codex' } }]);
});

test('OrphanSchedule_SaysSoAndOffersOnlyUnschedule', async () => {
  await renderSnapshot({ jobs: [{ ...JOB, name: 'next-old', configured: false }] });
  const row = screen.getByRole('listitem', { name: 'Job next-old' });
  expect(row.textContent, 'because launchd still runs it though the config dropped it').toMatch(/not in config/);
  expect(within(row).queryByRole('button', { name: 'Run now' }), 'because the config no longer says what it runs').toBeNull();
});

test('JobWithoutASchedule_FoldsIntoOneLine', async () => {
  await renderSnapshot({ jobs: [JOB, { ...JOB, name: 'retro', job: 'retro', schedule: '', installed: false, state: 'not-installed' }] });
  expect(screen.queryByRole('listitem', { name: 'Job retro' }), 'because a job nobody scheduled is not a schedule to watch').toBeNull();
  expect(screen.getByText(/Not scheduled: retro/), 'because the owner still sees which jobs could run').not.toBeNull();
});

describe('outcome chips', () => {
  beforeEach(() => { vi.useFakeTimers({ toFake: ['setInterval', 'clearInterval'] }); });
  afterEach(() => { vi.useRealTimers(); });

  test('FinishedAction_ChipClearsAfterAWhile', async () => {
    let now = Date.parse(TAKEN_AT);
    await renderSnapshot({ jobs: [{ ...JOB, name: 'health' }] }, new FakeDaemon(), () => now);
    await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Pause' })); });
    expect(screen.queryByText('done'), 'because the button first says how the press ended').not.toBeNull();
    act(() => { now += OUTCOME_SHOWN_MS; vi.advanceTimersByTime(TICK_MS); });
    expect(screen.queryByText('done'), 'because an old outcome is noise once the owner has seen it').toBeNull();
  });
});
