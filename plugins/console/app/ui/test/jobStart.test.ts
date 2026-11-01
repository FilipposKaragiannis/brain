import { expect, test } from 'vitest';
import { ownArgs, pairSpec, scheduleName, scheduleProblem, scheduleSpec, startArgs, startFormFrom, startProblem, whenFrom } from '../src/jobStart.ts';

test('ScheduleArgs_FillTheForm', () => {
  expect(startFormFrom('codex gh#12 --max-steps 3 --workers 2', 'claude'), 'because Run… starts from what the schedule runs').toEqual({ host: 'codex', item: 'gh#12', workers: '2', maxSteps: '3', model: '', effort: '' });
});

test('NoScheduleArgs_TakesTheProjectsJobsHost', () => {
  expect(startFormFrom('', 'codex').host, 'because jobs.host names where unattended work runs').toBe('codex');
});

test('UnknownJobsHost_FallsBackToClaude', () => {
  expect(startFormFrom('', 'gemini').host, 'because next.sh takes claude or codex only').toBe('claude');
});

test('EmptyFields_AreLeftOut', () => {
  expect(startArgs({ host: 'claude', item: ' ', workers: '', maxSteps: '4', model: '', effort: '' }), 'because an empty field means the config value').toEqual({ host: 'claude', maxSteps: '4' });
});

test('ZeroWorkers_IsAProblem', () => {
  expect(startProblem({ host: 'claude', item: '', workers: '0', maxSteps: '', model: '', effort: '' }), 'because a run needs at least one worker').toBe('Workers is a whole number from 1 to 99.');
});

test('TwoItems_IsAProblem', () => {
  expect(startProblem({ host: 'claude', item: 'gh#1 gh#2', workers: '', maxSteps: '', model: '', effort: '' }), 'because next.sh takes one item').toBe('One item, such as gh#12.');
});

test('TooManySteps_IsAProblem', () => {
  expect(startProblem({ host: 'claude', item: '', workers: '', maxSteps: '1000', model: '', effort: '' }), 'because the daemon refuses more than 999 steps').toBe('Max steps is a whole number from 1 to 999.');
});

test('ItemOnManyWorkers_IsAProblem', () => {
  expect(startProblem({ host: 'claude', item: 'gh#12', workers: '2', model: '', maxSteps: '', effort: '' }), 'because next.sh runs one item on one worker').toBe('One item runs on one worker. Clear the item or set workers to 1.');
});

test('EffortTheHostDoesNotTake_IsAProblem', () => {
  expect(startProblem({ host: 'codex', item: '', workers: '', maxSteps: '', model: '', effort: 'max' }), 'because codex takes up to xhigh').toBe('codex takes low, medium, high, xhigh as effort.');
});

test('ScheduleSpec_PutsTheHostWordFirstAndOnlyTheSetOptions', () => {
  const form = { host: 'codex', item: '', workers: '2', maxSteps: '', model: 'gpt-6-sol', effort: '' };
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
  const form = { ...startFormFrom('', 'claude'), model: '', effort: '' };
  expect(pairSpec({ kind: 'every', count: '15', unit: 'm' }, form, '--dry-run'), 'because an empty model or effort is jobs.<host>.model and effort').toBe('every 15m claude --dry-run');
});
