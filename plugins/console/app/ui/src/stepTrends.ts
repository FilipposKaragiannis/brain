import type { IsoDay, StepDay, StepName } from '../../daemon/src/collectors/graphReport.ts';

/** How many steps get a chart: the ones that used the most time. The report's tables list every step. */
export const TRENDS_SHOWN = 6;
const MILLISECONDS_PER_DAY = 86400000;
const ISO_DAY_LENGTH = 10;

/** One step's days in the chart, oldest first, and the time its runs took in all on those days, in seconds. */
export type StepTrend = Readonly<{ step: StepName; days: readonly StepDay[]; seconds: number }>;

/** The steps whose runs took the most time in the daily lines, most first, each with its days oldest first. */
export function stepTrends(daily: readonly StepDay[]): readonly StepTrend[] {
  const byStep = new Map<StepName, StepDay[]>();
  for (const line of daily) byStep.set(line.step, [...(byStep.get(line.step) ?? []), line]);
  return [...byStep.entries()]
    .map(([step, days]) => ({
      step,
      days: [...days].sort((earlier, later) => earlier.day.localeCompare(later.day)),
      seconds: days.reduce((sum, line) => sum + line.seconds, 0),
    }))
    .sort((busier, quieter) => quieter.seconds - busier.seconds || busier.step.localeCompare(quieter.step))
    .slice(0, TRENDS_SHOWN);
}

function dayAt(moment: number): IsoDay {
  return new Date(moment).toISOString().slice(0, ISO_DAY_LENGTH) as IsoDay;
}

/** Every day from the first to the last of the trends: the time axis the charts share. */
export function daysCharted(trends: readonly StepTrend[]): readonly IsoDay[] {
  const days = trends.flatMap((trend) => trend.days.map((line) => line.day)).sort();
  const first = days[0];
  const last = days.at(-1);
  if (first === undefined || last === undefined) return [];
  const charted: IsoDay[] = [];
  for (let moment = Date.parse(`${first}T00:00:00Z`); moment <= Date.parse(`${last}T00:00:00Z`); moment += MILLISECONDS_PER_DAY) charted.push(dayAt(moment));
  return charted;
}
