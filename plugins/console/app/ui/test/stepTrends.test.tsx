import { act, cleanup, fireEvent, render, screen, within } from '@testing-library/react';
import { afterEach, expect, test } from 'vitest';
import type { StepDay } from '../../daemon/src/collectors/graphReport.ts';
import { StepTrends } from '../src/StepTrends.tsx';
import { daysCharted, stepTrends, TRENDS_SHOWN } from '../src/stepTrends.ts';

afterEach(cleanup);

function stepDay(day: string, step: string, median: number, runs: number): StepDay {
  return { day, step, runs, median, within: median, failed: 0, cost: 0, items: 1 };
}

/** Verify got slower over three days, with no run on the day between; review ran once, quickly. */
const DAILY: StepDay[] = [
  stepDay('2026-10-24', 'verify', 1200, 3),
  stepDay('2026-10-22', 'verify', 300, 2),
  stepDay('2026-10-23', 'review', 90, 1),
];

function panel(step: string): HTMLElement {
  return screen.getByRole('region', { name: `${step}: typical run time by day` });
}

function pointAt(step: string, day: string): void {
  const column = panel(step).querySelector(`[data-day="${day}"]`);
  if (column === null) throw new Error(`the ${step} chart has no column for ${day}`);
  fireEvent.pointerEnter(column);
}

test('StepTrends_StepsWithDifferentStepTime_AreOrderedBusiestFirst', () => {
  expect(stepTrends(DAILY).map((trend) => trend.step), 'because verify used an hour and ten minutes and review ninety seconds, and the owner looks at the costly step first').toEqual(['verify', 'review']);
});

test('StepTrends_DaysGivenOutOfOrder_AreChartedOldestFirst', () => {
  expect(stepTrends(DAILY)[0]?.days.map((line) => line.day), 'because a line drawn in the order the days arrived would run backwards').toEqual(['2026-10-22', '2026-10-24']);
});

test('StepTrends_MoreStepsThanTheChartsShown_KeepsTheBusiestOnes', () => {
  const many = Array.from({ length: TRENDS_SHOWN + 2 }, (_, index) => stepDay('2026-10-24', `step-${index}`, 100 * (index + 1), 1));
  const shown = stepTrends(many).map((trend) => trend.step);
  expect([shown.length, shown.includes('step-0')], 'because the two quietest steps give way, and the report\'s tables still list them').toEqual([TRENDS_SHOWN, false]);
});

test('DaysCharted_DayWithNoRunBetweenTwo_IsOnTheAxis', () => {
  expect(daysCharted(stepTrends(DAILY)), 'because a gap in the days must take its room, or two runs a week apart would look like neighbours').toEqual(['2026-10-22', '2026-10-23', '2026-10-24']);
});

test('StepTrends_StepThatGotFaster_ShowsItsLatestDayAsTheFigure', () => {
  render(<StepTrends daily={[stepDay('2026-10-22', 'verify', 1200, 1), stepDay('2026-10-24', 'verify', 300, 1)]} />);
  expect(within(panel('verify')).getByText('5m 00s'), 'because the number beside the name is where the step stands now, not its slowest day').toBeTruthy();
});

test('StepTrends_PointingAtADay_ReadsThatDayOutInEveryChart', async () => {
  render(<StepTrends daily={DAILY} />);
  await act(async () => { pointAt('verify', '2026-10-22'); });
  const readouts = [panel('verify'), panel('review')].map((chart) => within(chart).getByText(/^2026-10-22: /).textContent);
  expect(readouts, 'because one day is read across all steps at once, a step with no run that day included').toEqual(['2026-10-22: 5m 00s, 2 runs', '2026-10-22: no run']);
});

test('StepTrends_DailyNumbers_ListEveryDayWithoutThePointer', () => {
  render(<StepTrends daily={DAILY} />);
  const rows = within(screen.getByRole('table')).getAllByRole('row').slice(1).map((row) => within(row).getAllByRole('cell').map((cell) => cell.textContent));
  expect(rows, 'because the chart\'s numbers must be readable with no hover: newest day first, a step with no run said so').toEqual([
    ['2026-10-24', '20m 00s, 3 runs', 'no run'],
    ['2026-10-23', 'no run', '1m 30s, 1 run'],
    ['2026-10-22', '5m 00s, 2 runs', 'no run'],
  ]);
});

test('StepTrends_NoDailyLines_DrawsNothing', () => {
  const { container } = render(<StepTrends daily={[]} />);
  expect(container.textContent, 'because a flow that keeps no history yet has no chart, and an empty frame would look broken').toBe('');
});
