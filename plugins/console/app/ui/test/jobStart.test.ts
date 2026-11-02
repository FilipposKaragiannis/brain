import { expect, test } from 'vitest';
import { ownArgs, pairSpec, scheduleLine, scheduleName, scheduleParts, scheduleProblem, scheduleSpec, startArgs, startFormFrom, startProblem, whenFrom } from '../src/jobStart.ts';

test('ScheduleArgs_FillTheForm', () => {
  expect(startFormFrom('codex gh#12 --max-steps 3 --workers 2', 'claude'), 'because Run… starts from what the schedule runs').toEqual({ host: 'codex', item: 'gh#12', workers: '2', maxSteps: '3', model: '', effort: '', pick: '' });
});

test('NoScheduleArgs_TakesTheProjectsJobsHost', () => {
  expect(startFormFrom('', 'codex').host, 'because jobs.host names where unattended work runs').toBe('codex');
});

test('UnknownJobsHost_FallsBackToClaude', () => {
  expect(startFormFrom('', 'gemini').host, 'because next.sh takes claude or codex only').toBe('claude');
});

test('EmptyFields_AreLeftOut', () => {
  expect(startArgs({ host: 'claude', item: ' ', workers: '', maxSteps: '4', model: '', effort: '', pick: '' }), 'because an empty field means the config value').toEqual({ host: 'claude', maxSteps: '4' });
});

test('ZeroWorkers_IsAProblem', () => {
  expect(startProblem({ host: 'claude', item: '', workers: '0', maxSteps: '', model: '', effort: '', pick: '' }), 'because a run needs at least one worker').toBe('Workers is a whole number from 1 to 99.');
});

test('TwoItems_IsAProblem', () => {
  expect(startProblem({ host: 'claude', item: 'gh#1 gh#2', workers: '', maxSteps: '', model: '', effort: '', pick: '' }), 'because next.sh takes one item').toBe('One item, such as gh#12.');
});

test('TooManySteps_IsAProblem', () => {
  expect(startProblem({ host: 'claude', item: '', workers: '', maxSteps: '1000', model: '', effort: '', pick: '' }), 'because the daemon refuses more than 999 steps').toBe('Max steps is a whole number from 1 to 999.');
});

test('ItemOnManyWorkers_IsAProblem', () => {
  expect(startProblem({ host: 'claude', item: 'gh#12', workers: '2', model: '', maxSteps: '', effort: '', pick: '' }), 'because next.sh runs one item on one worker').toBe('One item runs on one worker. Clear the item or set workers to 1.');
});

test('EffortTheHostDoesNotTake_IsAProblem', () => {
  expect(startProblem({ host: 'codex', item: '', workers: '', maxSteps: '', model: '', effort: 'max', pick: '' }), 'because codex takes up to xhigh').toBe('codex takes low, medium, high, xhigh as effort.');
});

test('ScheduleSpec_PutsTheHostWordFirstAndOnlyTheSetOptions', () => {
  const form = { host: 'codex', item: '', workers: '2', maxSteps: '', model: 'gpt-6-sol', effort: '', pick: '' };
  expect(scheduleSpec({ kind: 'every', count: '30', unit: 'm' }, form), 'because flow reads a leading host word as the schedule\'s host').toBe('every 30m codex --workers 2 --model gpt-6-sol');
  expect(scheduleSpec({ kind: 'weekly', day: 'sun', time: '07:00' }, { ...form, workers: '', model: '', item: 'gh#81' }), 'because an item runs only that item each time').toBe('weekly sun 07:00 codex gh#81');
});

test('EmptyLabel_NamesTheJobsOwnSchedule', () => {
  expect([scheduleName('next', ''), scheduleName('next', 'codex')], 'because an empty name replaces the job\'s schedule').toEqual(['next', 'next-codex']);
});

test('BadTime_IsAProblem', () => {
  expect(scheduleProblem('', { kind: 'daily', time: '2am' }), 'because launchd needs an hour and a minute').toBe('A time is HH:MM, such as 02:00.');
});

test('ScheduleTimes_FillTheForm', () => {
  expect([whenFrom('every 2h'), whenFrom('daily 02:00'), whenFrom('weekly sun 07:00'), whenFrom('')], 'because Schedule starts from the job\'s own time').toEqual([
    { kind: 'every', count: '2', unit: 'h' }, { kind: 'daily', time: '02:00' }, { kind: 'weekly', day: 'sun', time: '07:00' }, { kind: 'every', count: '30', unit: 'm' },
  ]);
});

test('OwnArgs_DropTheHostWordModelAndEffort', () => {
  expect(ownArgs('codex --batch 5 --model opus --effort low --keep-notes'), 'because the form sets those three, and the rest are the job\'s').toEqual(['--batch', '5', '--keep-notes']);
});

test('PairSpec_LeavesOutWhatIsFromConfig', () => {
  const form = { ...startFormFrom('', 'claude'), model: '', effort: '', pick: '' };
  expect(pairSpec({ kind: 'every', count: '15', unit: 'm' }, form, '--dry-run'), 'because an empty model or effort is jobs.<host>.model and effort').toBe('every 15m claude --dry-run');
});

test('ScheduleParts_LinesTheBuilderHoldsOrNot_RoundTripOrNull', () => {
  const lines: [string, string][] = [['next', 'every 30m --workers 2'], ['next', 'daily 02:00 codex gh#12 --max-steps 5 --model gpt-6-sol --effort high'], ['intake', 'weekly sun 07:00 claude --batch 5 --keep-notes --model opus']];
  for (const [job, line] of lines) expect(scheduleLine(scheduleParts(line, job, 'claude')!, job), `because the builder writes ${line} back as it read it`).toBe(line);
  const unreadable = ['weekly Sunday 07:00', 'every 30m --workers', 'every 30m --model opus --model sonnet', 'every 30m gh#1 gh#2', 'every 30m codex --effort max'];
  expect(unreadable.map((line) => scheduleParts(line, 'next', 'claude')), 'because a line the builder would rewrite differently stays text').toEqual(unreadable.map(() => null));
});

test('ScheduleArgsWithAFilter_FillThePick', () => {
  expect(startFormFrom('codex --pick mine --max-steps 3', 'claude').pick, 'because Run… starts from the filter the schedule runs through').toBe('mine');
});

test('StartArgs_AFilter_SentAsPick', () => {
  expect(startArgs({ ...startFormFrom('', 'claude'), pick: 'mine' }), 'because job.start passes it to jobs/next.sh as --pick').toEqual({ host: 'claude', pick: 'mine' });
});

test('FilterBesideAnItem_IsAProblem', () => {
  expect(startProblem({ ...startFormFrom('', 'claude'), item: 'gh#12', pick: 'mine' }), 'because next.sh refuses a filter beside a named item').toBe('A filter picks from the queue. Clear the item or the filter.');
});

test('FilterNameWithASpace_IsAProblem', () => {
  expect(startProblem({ ...startFormFrom('', 'claude'), pick: 'my items' }), 'because a filter name is letters, digits, _ and -').toBe('A filter is one name from pick in .flow/config.yaml, such as mine.');
});

test('ScheduleSpec_AFilter_AfterTheLimits', () => {
  expect(scheduleSpec({ kind: 'every', count: '30', unit: 'm' }, { ...startFormFrom('', 'claude'), maxSteps: '5', pick: 'mine' }), 'because the schedule runs next.sh through the filter, as jobs.schedule.next-mine says').toBe('every 30m claude --max-steps 5 --pick mine');
});

test('ScheduleParts_AFilter_RoundTripsThroughTheBuilder', () => {
  const line = 'every 30m --max-steps 5 --pick mine';
  expect(scheduleParts(line, 'next', 'claude')?.form.pick, 'because the builder shows the filter in its own field').toBe('mine');
  expect(scheduleLine(scheduleParts(line, 'next', 'claude')!, 'next'), 'because the builder writes the filter back as it read it').toBe(line);
});
