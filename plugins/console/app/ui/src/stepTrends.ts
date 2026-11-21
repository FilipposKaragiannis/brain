import type { StepDay } from '../../daemon/src/collectors/graphReport.ts';

/** How many steps get a chart: the ones that used the most time. The report's tables list every step. */
export const TRENDS_SHOWN = 6;
const MILLISECONDS_PER_DAY = 86400000;
const ISO_DAY_LENGTH = 10;

/** One step's days in the chart, oldest first, and the step time they add up to, in seconds. */
export type StepTrend = { step: string; days: StepDay[]; seconds: number };

/** The steps that used the most time in the daily lines, most first, each with its days oldest first. */
export function stepTrends(daily: StepDay[]): StepTrend[] {
  const byStep = new Map<string, StepDay[]>();
  for (const line of daily) byStep.set(line.step, [...(byStep.get(line.step) ?? []), line]);
  return [...byStep.entries()]
    .map(([step, days]) => ({
      step,
      days: [...days].sort((earlier, later) => earlier.day.localeCompare(later.day)),
      seconds: days.reduce((sum, line) => sum + line.median * line.runs, 0),
    }))
    .sort((busier, quieter) => quieter.seconds - busier.seconds || busier.step.localeCompare(quieter.step))
    .slice(0, TRENDS_SHOWN);
}

/** Every day from the first to the last of the trends, as ISO days: the time axis the charts share. */
export function daysCharted(trends: StepTrend[]): string[] {
  const days = trends.flatMap((trend) => trend.days.map((line) => line.day)).sort();
  const first = days[0];
  const last = days.at(-1);
  if (first === undefined || last === undefined) return [];
  const charted: string[] = [];
  for (let moment = Date.parse(`${first}T00:00:00Z`); moment <= Date.parse(`${last}T00:00:00Z`); moment += MILLISECONDS_PER_DAY) {
    charted.push(new Date(moment).toISOString().slice(0, ISO_DAY_LENGTH));
  }
  return charted;
}
